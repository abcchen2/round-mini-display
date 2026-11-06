import Foundation

/// GCJ-02 progress is bounded by elapsed time and physical movement, including loops.
struct MotorRouteTracker {
    struct Match { let progress: Double; let offset: Double; let arrived: Bool; var needsReplan = false }
    private let shape: RouteShape
    private var progress=0.0,lastTime:Double?,lastPoint:MotorPoint?
    private var armed=false,arrivalCount=0,nearSince=0.0
    private var recoveryCandidate: (point: MotorPoint, accuracy: Double, time: Double)?
    private var recoveryNeedsReplan = false
    init(_ points:[MotorPoint]) {shape=RouteShape(points:points)}
    mutating func update(_ point:MotorPoint,accuracy:Double,now:Double)->Match? {
        guard MotorRequest.valid(point.lat,point.lng),accuracy.isFinite,accuracy>=0,accuracy<=50,now.isFinite,shape.points.count>=2 else{return nil}
        if let previous=lastTime,now-previous<0.4{return nil}
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
            let score=d+(lastTime == nil ? 0 : abs(p-progress)*0.015)
            if score<best {best=score;offset=d;along=p}
        }
        lastTime=now;lastPoint=point
        if offset<=max(55,accuracy*1.5) {progress=max(progress,along)}
        let remain=max(0,total-progress),end=RouteShape.metres(point,shape.points.last!)
        if remain>min(60,total*0.6),end>min(35,total*0.5),offset<=max(55,accuracy*1.5) {armed=true}
        let near=armed && accuracy<=25 && offset<=30 && remain<=min(30,total*0.15) && end<=min(30,total*0.2)
        if near {if arrivalCount==0{nearSince=now};arrivalCount+=1}else{arrivalCount=0;nearSince=0}
        return Match(progress:progress,offset:offset,arrived:near && arrivalCount>=3 && now-nearSince>=2)
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
        recoveryNeedsReplan=true;armed=false
        return Match(progress:progress,offset:0,arrived:false,needsReplan:true)
    }
}
