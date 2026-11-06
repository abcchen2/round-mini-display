
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){precondition(value(),message);checks+=1}
func spin(_ seconds:Double){let end=Date().addingTimeInterval(seconds);while Date()<end{_ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}}
func busy(_ s:WebMotorSession)->Bool{Mirror(reflecting:s).children.first{$0.label=="rerouting"}!.value as! Bool}
func makeRoute(_ lat:Double=30)->MotorRoute {
    let points=[MotorPoint(lat:lat,lng:104),MotorPoint(lat:lat+0.02,lng:104)]
    return MotorRoute(request:MotorRequest(start:points[0],end:points[1]),points:points,steps:[MotorStep(instruction:"continue",road:"A",action:"",end:1)],seconds:200)
}
func fix(_ lat:Double,_ lng:Double)->CLLocation {
    CLLocation(coordinate:CLLocationCoordinate2D(latitude:lat,longitude:lng),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,course:90,speed:8,timestamp:Date())
}
func trigger(_ session:WebMotorSession){
    session.onFix(fix(30.005,104));spin(0.5)
    session.onFix(fix(30.005,104.0004));spin(1.05)
    session.onFix(fix(30.005,104.00045));spin(0.1)
}

// Trigger times use the actual new Swift policy and physical 90-degree fixtures.
for (kmh,expected) in [(20,6.0),(30,5.0),(60,3.0)] {
    var policy=MotorReroutePolicy();var triggered:Double?
    for i in 0...30 where triggered==nil {
        if policy.observe(offset:Double(i)*Double(kmh)/3.6,accuracy:5,now:Double(i)){triggered=Double(i)}
    }
    check(triggered==expected,"adaptive confirmation timing")
    print("TRIGGER \(kmh)km/h = \(triggered!) seconds, excluding server")
}
var jitter=MotorReroutePolicy()
for i in 0..<30 {check(!jitter.observe(offset:i%2==0 ? 35:10,accuracy:5,now:Double(i)),"one-frame GPS jumps cannot replan")}
var inaccurate=MotorReroutePolicy()
for i in 0..<10 {check(!inaccurate.observe(offset:45,accuracy:30,now:Double(i)),"uncertain positioning must raise threshold")}
check(!inaccurate.observe(offset:100,accuracy:55,now:20),"invalid accuracy rejected")
var gap=MotorReroutePolicy();_ = gap.observe(offset:40,accuracy:5,now:0)
check(!gap.observe(offset:40,accuracy:5,now:4),"GPS gap resets confirmation")
check(gap.observe(offset:40,accuracy:5,now:5),"confirmation resumes with new valid fixes")
let first=gap.begin(now:5)!
check(gap.begin(now:6)==nil,"one calculation at a time")
check(gap.expired(now:16.99)==nil && gap.expired(now:17)==first,"12-second deadline")
check(gap.finish(first,now:17,success:false),"failure releases lease")
check(gap.begin(now:24.9)==nil,"failure backoff is bounded")
let second=gap.begin(now:25)!
check(!gap.finish(first,now:26,success:true) && gap.pending==second,"late old result cannot close new request")
gap.reset();check(gap.begin(now:26) != nil,"new journey resets old cooldown")

let session=WebMotorSession.shared,original=makeRoute(),newRoute=makeRoute(30.001)
MotorRoutes.answer=newRoute

MotorRoutes.mode = .empty;session.start(original,simulate:false);BleLink.shared.messages=[];trigger(session)
check(!busy(session) && session.running && session.route?.id==original.id,"empty route restores running state and retains original route")
check(BleLink.shared.messages.contains("#y,1") && BleLink.shared.messages.last=="#y,0","every early failure clears small-screen rerouting")
session.stop()

MotorRoutes.mode = .failure;session.start(original,simulate:false);trigger(session)
check(!busy(session) && session.running && session.status.contains("重算失败"),"network failure keeps old navigation usable")
session.stop()

MotorRoutes.mode = .success;session.start(original,simulate:false);trigger(session)
check(!busy(session) && session.running && session.route?.id==newRoute.id,"success installs new route and releases lease")
check(session.position==nil && session.turnDirection.isEmpty && session.turnMetres==0,"new route waits for a fresh fix instead of displaying the previous turn")
session.stop()

// Real session watchdog: suspend I/O without honoring cancellation, keep GPS callbacks active.
MotorRoutes.mode = .suspend;session.start(original,simulate:false);BleLink.shared.messages=[];trigger(session)
check(busy(session),"suspended I/O enters bounded recalculation")
let pendingAt=ProcessInfo.processInfo.systemUptime
while ProcessInfo.processInfo.systemUptime-pendingAt<13.3 {spin(0.5);session.onFix(fix(30.005,104.00045))}
check(!busy(session) && session.running && session.route?.id==original.id,"watchdog recovers even when I/O never resumes")
check(session.status.contains("重算失败"),"timeout remains visible instead of being instantly overwritten by GPS")
let held=session.route!.id
let late=MotorRoutes.waiting.removeFirst();late.resume(returning:[newRoute]);spin(0.2)
check(session.route?.id==held && !busy(session),"late timed-out response cannot replace displayed route")
session.stop()

// Stop/start cannot be undone by the old asynchronous result.
session.start(original,simulate:false);trigger(session);check(busy(session),"new session has no inherited backoff")
let old=MotorRoutes.waiting.removeFirst();session.stop();session.start(newRoute,simulate:false)
old.resume(returning:[original]);spin(0.2)
check(session.running && session.route?.id==newRoute.id && !busy(session),"old response cannot revive cancelled journey")
session.stop()

let endedCalls=MotorRoutes.calls
session.replan(MotorPoint(lat:30.02,lng:104));spin(0.1)
check(MotorRoutes.calls==endedCalls && !busy(session),"an arrival/stop cannot launch a leftover recalculation")

session.start(original,simulate:false)
let queuedCalls=MotorRoutes.calls
session.replan(MotorPoint(lat:30.005,lng:104.001));session.stop();spin(0.2)
check(MotorRoutes.calls==queuedCalls && !busy(session),"stopping a queued request prevents its network operation from starting")

// Matcher correctness against baseline for loops, boundaries and movement.
let line=(0...1200).map{MotorPoint(lat:30+Double($0)/111320,lng:104)}
var current=MotorRouteTracker(line),legacy=LegacyMotorRouteTracker(line)
for i in 0...600 {
    let p=MotorPoint(lat:30+Double(i)/111320,lng:104+(i%19==0 ? 0.0003:0))
    let a=current.update(p,accuracy:5,now:Double(i)),b=legacy.update(p,accuracy:5,now:Double(i))
    check((a==nil)==(b==nil),"matcher acceptance parity")
    if let a=a,let b=b {check(abs(a.progress-b.progress)<1e-8 && abs(a.offset-b.offset)<1e-8 && a.arrived==b.arrived,"optimized matcher preserves progress and arrival")}
}
let long=(0...149999).map{MotorPoint(lat:30+Double($0)/111320,lng:104)}
var fast=MotorRouteTracker(long),slow=LegacyMotorRouteTracker(long)
let begun=ProcessInfo.processInfo.systemUptime
for i in 0..<1000 {_ = fast.update(long[i],accuracy:5,now:Double(i))}
let fastSeconds=ProcessInfo.processInfo.systemUptime-begun,oldAt=ProcessInfo.processInfo.systemUptime
for i in 0..<1000 {_ = slow.update(long[i],accuracy:5,now:Double(i))}
let slowSeconds=ProcessInfo.processInfo.systemUptime-oldAt
print("MATCHER macOS host (not iPhone): optimized=\(fastSeconds)s baseline=\(slowSeconds)s for 1000 fixes / 150000 points")
print("PASS production Swift session, timeout/empty/failure/cancellation/late results, geometry parity: \(checks) checks")

// Exercise the actual render loop, including a journey that starts inside the near gate.
do {
    let p = MotorPoint(lat:30,lng:104)
    let end = MotorPoint(lat:30+150.0/111320,lng:104)
    let short = MotorRoute(request:MotorRequest(start:p,end:end),points:[p,end],
        steps:[MotorStep(instruction:"右转",road:"A",action:"右转",end:1,distance:150)],seconds:60)
    Speech.shared.messages=[]
    BleLink.shared.messages=[];MapFeeder.shared.locations=[]
    session.start(short,simulate:false)
    check(session.speed==0 && session.position==nil && Speech.shared.messages.isEmpty,"real navigation waits for a fix without simulated speed or speech")
    check(MapFeeder.shared.locations.isEmpty && !BleLink.shared.messages.contains("#x,0") && !BleLink.shared.messages.contains("#v,60"),"planning origin is not published as a live position")
    check(BleLink.shared.messages.contains("#NW,1"),"device uses the neutral waiting state before first GPS")
    for _ in 0..<200 {session.render(p,off:0)}
    check(Speech.shared.messages.count==1,"starting inside 200m must not alternate 200/500m announcements")
    session.stop();Speech.shared.messages=[]
    session.start(short,simulate:true)
    session.paused=true
    for _ in 0..<200 {session.render(p,off:0)}
    check(Speech.shared.messages.count==1,"simulated navigation uses the same one-time gates")
    session.stop()

    Speech.shared.messages=[]
    session.start(original,simulate:false)
    WebRouteMetadata.shared.lampDistances=[40,300,800]
    for _ in 0..<200 {session.render(p,off:0)}
    check(Speech.shared.messages==["前方路口，注意信号灯"],"starting within 60m must skip the outdated 300m gate")
    for along in [100.0,250,260,290,310,520,750] {
        session.progress=along
        for _ in 0..<20 {session.render(p,off:0)}
    }
    check(Speech.shared.messages==["前方路口，注意信号灯","前方200米有红绿灯","前方路口，注意信号灯","前方280米有红绿灯","前方路口，注意信号灯"],
        "each light advances through its gates once and speaks its actual distance")
    session.stop()

    let nearTurn = MotorRoute(request:MotorRequest(start:p,end:original.points.last!),points:original.points,
        steps:[MotorStep(instruction:"右转",road:"A",action:"右转",end:1,distance:400)],seconds:200)
    session.start(nearTurn,simulate:false);WebRouteMetadata.shared.lampDistances=[40]
    Speech.shared.messages=[]
    session.progress=session.cum.last!*0.6 // 160m to the turn; light also lies within 60m.
    WebRouteMetadata.shared.lampDistances=[session.progress+40]
    for _ in 0..<200 {session.render(p,off:0)}
    check(Speech.shared.messages.count==1 && Speech.shared.messages[0].contains("右转"),"near turns suppress traffic-light speech")
    session.stop()
    Speech.shared.messages=[];session.start(short,simulate:false)
    check(Speech.shared.messages.isEmpty,"restart also waits for a physical fix")
    session.onFix(fix(p.lat,p.lng))
    check(Speech.shared.messages.count==1,"new journey resets all announcement gates")
    check(session.position != nil && session.speed==28,"first physical fix supplies the actual position and measured speed")
    session.stop()
    print("PASS real/simulated render-loop speech, stopped vehicle, consecutive lights, turn priority and restart")
}

do {
    let origin=MotorPoint(lat:30,lng:104),far=MotorPoint(lat:30+8000.0/111320,lng:104)
    let points=[origin,far,origin,far]
    let route=MotorRoute(request:MotorRequest(start:origin,end:far),points:points,
        steps:[MotorStep(instruction:"old turn",road:"A",action:"左转",end:3)],seconds:900)
    session.start(route,simulate:false)
    var interrupted=MotorRouteTracker(points)
    _=interrupted.update(origin,accuracy:5,now:ProcessInfo.processInfo.systemUptime-1000)
    session.tracker=interrupted;MotorRoutes.mode = .failure
    Speech.shared.messages=[];BleLink.shared.messages=[]
    let calls=MotorRoutes.calls
    session.onFix(fix(30+4000.0/111320,104));spin(0.45)
    session.onFix(fix(30+4020.0/111320,104));spin(0.2)
    check(session.recoveringPosition && MotorRoutes.calls==calls+1,"ambiguous recovered positions trigger bounded replanning")
    check(session.position != nil && session.turnDirection.isEmpty && session.turnMetres==0,"phone follows the recovered position without the old turn")
    check(session.status.contains("重算失败"),"failed recovery replan keeps its error visible")
    for i in 1...3 {
        spin(0.45);session.onFix(fix(30+(4020+Double(i)*10)/111320,104))
    }
    check(MotorRoutes.calls==calls+1 && session.recoveringPosition,"cooldown does not restart plans on every GPS fix")
    check(Speech.shared.messages.isEmpty && !BleLink.shared.messages.contains(where:{$0.hasPrefix("L,")}),"failed/pending recovery cannot replay old guidance")
    session.stop()

    let shapeOnly=MotorRoute(request:MotorRequest(start:origin,end:far),points:[origin,far],
        steps:[MotorStep(instruction:"左家庄路",road:"左家庄路",action:"",end:1)],seconds:500,detailedGuidance:false)
    Speech.shared.messages=[];BleLink.shared.messages=[]
    session.start(shapeOnly,simulate:true);session.paused=true
    check(session.turnDirection.isEmpty && Speech.shared.messages.isEmpty,"a geometry-only route has no fabricated turn or turn speech")
    let turns=Set(["L","R","S","SL","SR","U"])
    check(!BleLink.shared.messages.contains(where:{turns.contains(String($0.split(separator:",").first ?? ""))}),"device does not receive a fabricated straight/left/right instruction")
    WebRouteMetadata.shared.lampDistances=[40]
    session.render(origin,off:0)
    check(Speech.shared.messages==["前方路口，注意信号灯"],"verified lamp events remain independent of missing maneuver data")
    session.stop()
    print("PASS first-GPS startup, persistent recovery suppression/cooldown and geometry-only route guidance")
}
