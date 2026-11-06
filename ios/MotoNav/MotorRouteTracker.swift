import Foundation

/// GCJ-02 progress is bounded by elapsed time and physical movement, including loops.
struct MotorRouteTracker {
    struct Match { let progress: Double; let offset: Double; let arrived: Bool; var needsReplan = false; var arrivalCandidate = false }
    private let shape: RouteShape
    private var progress=0.0,lastTime:Double?,lastPoint:MotorPoint?
    private var arrivalCount=0,nearSince=0.0
    private var closestRemaining=Double.infinity
    private var terminalApproachObserved=false
    private var arrivalLock: Match?
    private var recoveryCandidate: (point: MotorPoint, accuracy: Double, time: Double)?
    private var recoveryNeedsReplan = false
    init(_ points:[MotorPoint]) {shape=RouteShape(points:points)}
    /// Route direction (degrees, 0 = north) around a progress value; nil where the shape folds back on itself.
    func bearing(at along:Double)->Double? {
        guard shape.points.count>=2,let total=shape.cum.last,total>0 else {return nil}
        let a=shape.at(max(0,along-8)),b=shape.at(min(total,along+12))
        guard RouteShape.metres(a,b)>=5 else {return nil}
        return RouteShape.bearing(a,b)
    }
    /// - Parameter heading: measured course in degrees when it is reliable. It only breaks ties between
    ///   passages that run in opposite directions (out-and-back roads, U-turns); nil keeps the geometric match.
    mutating func update(_ point:MotorPoint,accuracy:Double,now:Double,heading:Double?=nil)->Match? {
        if let arrivalLock=arrivalLock {return arrivalLock}
        guard now.isFinite,shape.points.count>=2 else{return nil}
        if let previous=lastTime,now-previous<0.4{return nil}
        guard MotorRequest.valid(point.lat,point.lng),accuracy.isFinite,accuracy>=0,accuracy<=50 else {
            arrivalCount=0;return nil
        }
        if recoveryNeedsReplan, let previous=lastTime, let last=lastPoint {
            guard RouteShape.metres(last,point)<=max(80,(now-previous)*75)+accuracy*2 else {return nil}
            lastTime=now;lastPoint=point
            return Match(progress:progress,offset:0,arrived:false,needsReplan:true)
        }
        let total=shape.cum.last ?? 0
        var lower=0.0,upper=total
        if let previous=lastTime,let last=lastPoint {
            if now-previous>4 {arrivalCount=0;nearSince=0}
            let travel=RouteShape.metres(last,point),reach=min(2500,max(80,min(30,now-previous)*75))
            if travel>reach+accuracy*2 {
                arrivalCount=0
                return recover(point,accuracy:accuracy,now:now,elapsed:now-previous)
            }
            recoveryCandidate=nil
            lower=max(0,progress-80);upper=min(total,progress+min(reach,max(100,travel+accuracy*2+35)))
        } else if RouteShape.metres(point,shape.points[0])<100 {upper=min(total,300)}
        let scale=cos(point.lat * .pi/180)*111320
        var best=Double.infinity,offset=Double.infinity,along=progress
        func boundary(_ value:Double,strict:Bool)->Int {
            var lo=0,hi=shape.cum.count
            while lo<hi {let m=(lo+hi)/2;if strict ? shape.cum[m]<=value : shape.cum[m]<value {lo=m+1}else{hi=m}}
            return lo
        }
        let first=max(1,boundary(lower,strict:false)),last=min(shape.points.count-1,boundary(upper,strict:true))
        guard first<=last else {return nil}
        for i in first...last {
            let a=shape.points[i-1],b=shape.points[i],length=shape.cum[i]-shape.cum[i-1]
            if length<0.01{continue}
            let ax=(a.lng-point.lng)*scale,ay=(a.lat-point.lat)*111320,dx=(b.lng-a.lng)*scale,dy=(b.lat-a.lat)*111320
            let t0=min(1,max(0,-(ax*dx+ay*dy)/max(0.001,dx*dx+dy*dy)))
            let t=max(max(0,(lower-shape.cum[i-1])/length),min(min(1,(upper-shape.cum[i-1])/length),t0))
            let d=hypot(ax+t*dx,ay+t*dy),p=shape.cum[i-1]+t*length
            var score=d+(lastTime == nil ? 0 : abs(p-progress)*0.015)
            if let heading=heading,lastTime != nil {
                // Opposite-direction passages at the same place: prefer the one matching the travel direction.
                let diff=RouteShape.angle(heading,atan2(dx,dy)*180 / .pi)
                if diff>100 {score+=(diff-100)/80*12}
            }
            if score<best {best=score;offset=d;along=p}
        }
        let previousProgress=progress, hadPreviousFix=lastTime != nil
        lastTime=now;lastPoint=point
        if offset<=max(55,accuracy*1.5) {progress=max(progress,along)}
        let approachStart=total-min(140,total*0.5)
        if hadPreviousFix,previousProgress<approachStart,along>=approachStart,offset<=18 {
            terminalApproachObserved=true
        }
        // Use this fix's projection, not the furthest historical progress: backing away cancels a candidate.
        let remaining=max(0,total-along),end=RouteShape.metres(point,shape.points.last!)
        let holding=arrivalCount>0
        let shortFinalHalf=total<20 && along>=total*0.5 && end<RouteShape.metres(point,shape.points[0])
        let entryRemaining=shortFinalHalf ? max(5,total*0.25) : min(30,total*0.25)
        let holdRemaining=max(entryRemaining,min(48,total*0.4))
        // A rider can turn sideways into a compound, but riding back along the approach is a departure.
        let retreating=holding && remaining-closestRemaining>max(12,min(25,accuracy))
        let inTerminalZone=holding
            ? !retreating && accuracy<=45 && remaining<=holdRemaining && end<=55 && offset<=50
            : accuracy<=40 && remaining<=entryRemaining && end<=35 && offset<=min(25,max(12,accuracy))
        var candidate=inTerminalZone
        if candidate && !holding && !terminalApproachObserved {
            // A cold start may be on a different passage through the destination (bridge or return leg).
            let nearby=shape.projections(point,maximum:max(12,accuracy))
            candidate = !nearby.contains { abs($0.along-along)>max(45,accuracy*2+5) }
        }
        if candidate {
            if arrivalCount==0 {nearSince=now;closestRemaining=remaining}
            else {closestRemaining=min(closestRemaining,remaining)}
            arrivalCount+=1
        } else {arrivalCount=0}
        let result=Match(progress:progress,offset:offset,arrived:arrivalCount>=3 && now-nearSince>=2,arrivalCandidate:candidate)
        if result.arrived {arrivalLock=result}
        return result
    }

    /// A long outage needs two consistent fixes. A single distant GPS jump never moves progress.
    private mutating func recover(_ point: MotorPoint, accuracy: Double, now: Double, elapsed: Double) -> Match? {
        guard elapsed>=30 else {return nil}
        guard let previous=recoveryCandidate else {
            recoveryCandidate=(point,accuracy,now);return nil
        }
        let dt=now-previous.time
        guard dt>=0.4 else {return nil}
        guard dt<=5,RouteShape.metres(previous.point,point)<=max(80,dt*75)+accuracy+previous.accuracy else {
            recoveryCandidate=(point,accuracy,now);return nil
        }
        let lower=max(0,progress-80),upper=min(shape.cum.last ?? 0,progress+elapsed*75)
        func projection(_ p: MotorPoint, _ accuracy: Double) -> RouteShape.Projection? {
            RouteShape.unique(shape.projections(p,maximum:max(25,accuracy*1.5)).filter{$0.along>=lower && $0.along<=upper})
        }
        let before=projection(previous.point,previous.accuracy),current=projection(point,accuracy)
        lastTime=now;lastPoint=point;recoveryCandidate=nil;arrivalCount=0;nearSince=0
        if let before=before,let current=current,
           current.along>=before.along-accuracy-previous.accuracy,
           abs(current.along-before.along)<=RouteShape.metres(previous.point,point)+accuracy+previous.accuracy+35 {
            progress=max(progress,current.along)
            return Match(progress:progress,offset:current.offset,arrived:false)
        }
        // Loops, parallel roads and off-route fixes cannot establish which passage is current.
        // Retain route progress, but accept fresh physical positions for a bounded replan.
        recoveryNeedsReplan=true;terminalApproachObserved=false
        return Match(progress:progress,offset:0,arrived:false,needsReplan:true)
    }
}
