import Foundation

/// Guidance consumes the same GCJ-02 geometry that the map draws. No map/provider conversion here.
enum MotorGuidance {
    static func remaining(to step: MotorStep, route: MotorRoute, progress: Double) -> Int {
        max(0,Int((route.cum[step.end]-progress).rounded()))
    }
    private static func actionText(_ step: MotorStep) -> String {
        let action=step.action.trimmingCharacters(in:.whitespacesAndNewlines)
        if !action.isEmpty {return action}
        // Raw provider prose embeds the original, fixed step length. It is not a live instruction.
        return step.road.isEmpty ? "沿路线前进" : "沿\(step.road)行驶"
    }
    static func instruction(_ step: MotorStep) -> String {
        let action=actionText(step)
        return step.road.isEmpty || step.action.isEmpty ? action : "\(step.road) · \(action)"
    }
    static func spoken(_ step: MotorStep, distance: Int) -> String {
        let action=actionText(step)
        return distance<=15 ? "前方路口，\(action)" : "前方\(distance)米，\(action)"
    }
    /// 转向播报三档（由远到近），按到路口的剩余时间而不是固定米数：约 30 秒、12 秒、3 秒前各播一次，
    /// 并限制在合理范围内。60 km/h 时为 500 / 200 / 50 米，与原固定档位接近；停车或低速时取下限。
    static func turnThresholds(kmh: Int) -> [Int] {
        let v = Double(min(200, max(0, kmh))) / 3.6
        func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Int { Int(min(hi, max(lo, x)).rounded()) }
        return [clamp(v * 30, 250, 800), clamp(v * 12, 100, 300), clamp(v * 3, 30, 80)]
    }
    static func reliableHeading(speed: Double, course: Double, courseAccuracy: Double, accuracy: Double) -> Double? {
        guard speed.isFinite,speed>=4,course.isFinite,(0..<360).contains(course),
              courseAccuracy.isFinite,(0...30).contains(courseAccuracy),accuracy.isFinite,(0...25).contains(accuracy) else {return nil}
        return course
    }
}

/// Advance after entering the outgoing geometry, not merely because a noisy fix reaches the junction.
struct MotorStepProgress {
    private(set) var index=0
    private var proposed: Int?, count=0, since=0.0, last: Double?
    private mutating func clear() {proposed=nil;count=0;last=nil}
    mutating func update(route: MotorRoute, progress: Double, point: MotorPoint, accuracy: Double,
                         heading: Double?, now: Double, simulation: Bool) -> Int {
        guard index<route.steps.count-1 else {return index}
        if simulation || !route.detailedGuidance {
            while index<route.steps.count-1 && progress>=route.cum[route.steps[index].end] {index+=1}
            clear();return index
        }
        guard progress>=route.cum[route.steps[index].end]+5 else {clear();return index}
        var next=index+1
        while next<route.steps.count-1 && progress>route.cum[route.steps[next].end]+15 {next+=1}
        let step=route.steps[next]
        guard step.end>step.start else {clear();return index}
        let outgoing=RouteShape(points:Array(route.points[step.start...step.end]))
        let limit=max(12,min(30,accuracy))
        guard let projection=outgoing.projections(point,maximum:limit).min(by:{$0.offset<$1.offset}),
              projection.along>=min(8,(outgoing.cum.last ?? 0)*0.3) else {clear();return index}
        let turn=route.cum[step.start]
        let a=route.at(max(0,turn-30)),b=route.points[step.start]
        let scale=111320*cos(point.lat * .pi/180)
        let dx=(b.lng-a.lng)*scale,dy=(b.lat-a.lat)*111320
        // Compare with the incoming road's extension: simply driving straight past a shallow fork
        // must not count as making the planned turn into the adjacent branch.
        let incomingOffset=abs((point.lng-a.lng)*scale*dy-(point.lat-a.lat)*111320*dx)/max(0.001,hypot(dx,dy))
        let direction=RouteShape.bearing(outgoing.at(0),outgoing.at(min(20,outgoing.cum.last ?? 0)))
        let aligned=heading.map{RouteShape.angle($0,direction)<=60} ?? false
        if let heading=heading,RouteShape.angle(heading,direction)>100 {clear();return index}
        let clearlyOutgoing=projection.offset+max(4,min(12,accuracy*0.35))<incomingOffset
        let turnAngle=RouteShape.angle(RouteShape.bearing(a,b),direction)
        let confirmed: Bool
        if turnAngle>=140 {confirmed=aligned}
        else if turnAngle>=25 {confirmed=clearlyOutgoing && (heading == nil || aligned)}
        else {confirmed=aligned || projection.along>=max(15,min(40,accuracy*1.2))}
        guard confirmed else {clear();return index}
        if proposed != next || last.map({now-$0>3}) == true {proposed=next;count=0;since=now}
        if let last=last,now-last<0.4 {return index}
        last=now;count+=1
        if count>=2,now-since>=0.8 {index=next;clear()}
        return index
    }
}

/// Choose among AMap's actual alternatives; never reverse or synthesize a route to match a heading.
enum MotorRouteSelection {
    static func preferred(_ routes: [MotorRoute], from point: MotorPoint, heading: Double?) -> MotorRoute? {
        guard let first=routes.first,let heading=heading,heading.isFinite else {return routes.first}
        func departure(_ route: MotorRoute) -> Double? {
            guard let total=route.cum.last,total>=30,
                  RouteShape.metres(point,route.points[0])<=35 else {return nil}
            let end=min(80,total),a=route.at(5),b=route.at(end)
            guard RouteShape.metres(a,b)>=min(25,end*0.6) else {return nil}
            let bearing=RouteShape.bearing(a,b)
            // A short U shape cannot claim a direction based on its chord alone.
            let mid=route.at(end*0.5)
            let initial=route.at(min(15,end*0.4))
            guard RouteShape.metres(a,initial)>=5,
                  RouteShape.angle(RouteShape.bearing(a,initial),bearing)<=45,
                  RouteShape.angle(RouteShape.bearing(a,mid),bearing)<=45,
                  RouteShape.angle(RouteShape.bearing(mid,b),bearing)<=45 else {return nil}
            return RouteShape.angle(heading,bearing)
        }
        guard let delta=departure(first),delta>120 else {return first}
        return routes.dropFirst().first { route in
            guard let delta=departure(route),delta<60 else {return false}
            if first.seconds>0,route.seconds>0 {return Double(route.seconds)<=Double(first.seconds)*1.2+60}
            return Double(route.totalMeters)<=Double(first.totalMeters)*1.2+100
        } ?? first
    }
    static func ordered(_ routes: [MotorRoute], from point: MotorPoint, heading: Double?) -> [MotorRoute] {
        guard let preferred=preferred(routes,from:point,heading:heading) else {return []}
        return [preferred]+routes.filter{$0.id != preferred.id}
    }
}
