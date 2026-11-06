
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
for i in 0..<10 {check(!inaccurate.observe(offset:35,accuracy:30,now:Double(i)),"uncertain positioning must raise threshold")}
check(!inaccurate.observe(offset:100,accuracy:55,now:20),"invalid accuracy rejected")
// 城市里常见 35~50 米精度：门限封顶 60 米，不再要偏出 80 米才重算
check(MotorReroutePolicy.threshold(accuracy:50)==60 && MotorReroutePolicy.threshold(accuracy:5)==25,"threshold capped for typical urban accuracy")
var urban=MotorReroutePolicy()
check(!urban.observe(offset:65,accuracy:45,now:0) && urban.observe(offset:65,accuracy:45,now:1),"poor accuracy still confirms a 65m deviation in two fixes")
// 迟滞：门限附近抖动（介于 0.6 倍门限和门限之间）不清零已累计的偏航确认
var hysteresis=MotorReroutePolicy()
check(!hysteresis.observe(offset:30,accuracy:5,now:0) && !hysteresis.observe(offset:20,accuracy:5,now:1),"near-threshold jitter holds")
check(hysteresis.observe(offset:30,accuracy:5,now:2),"second off-route fix after jitter confirms deviation")
// 逆向行驶：偏移几乎为 0，靠航向 3 笔 / 2 秒确认
var reverse=MotorReroutePolicy()
check(!reverse.observe(offset:3,accuracy:5,now:0,headingDelta:175) && !reverse.observe(offset:3,accuracy:5,now:1,headingDelta:170),"reverse needs three fixes")
check(reverse.observe(offset:4,accuracy:5,now:2,headingDelta:178),"reverse travel triggers replan without lateral offset")
// 小角度分叉：偏移 18 米未到 25 米门限，但航向偏 50 度持续 3 笔
var fork=MotorReroutePolicy()
check(!fork.observe(offset:16,accuracy:5,now:0,headingDelta:50) && !fork.observe(offset:17,accuracy:5,now:1,headingDelta:50),"fork needs three fixes")
check(fork.observe(offset:18,accuracy:5,now:2,headingDelta:50),"diverging course confirms a fork early")
var curve=MotorReroutePolicy()
for i in 0..<10 {check(!curve.observe(offset:6,accuracy:5,now:Double(i),headingDelta:60),"on-route curve lag never replans")}
var flicker=MotorReroutePolicy()
for i in 0..<10 {check(!flicker.observe(offset:3,accuracy:5,now:Double(i),headingDelta:i%2==0 ? 170:10),"single reversed course samples never replan")}
// 跟踪器：同一位置正反两条通道（往返路 / 掉头），按行驶方向选通道
do {
    let a=MotorPoint(lat:30,lng:104),b=MotorPoint(lat:30+300.0/111320,lng:104)
    var outBack=MotorRouteTracker([a,b,a])
    _=outBack.update(MotorPoint(lat:30+280.0/111320,lng:104),accuracy:5,now:0,heading:0)
    _=outBack.update(MotorPoint(lat:30+299.0/111320,lng:104),accuracy:5,now:1,heading:0)
    let back=outBack.update(MotorPoint(lat:30+285.0/111320,lng:104),accuracy:5,now:2,heading:180)!
    check(back.progress>310,"heading selects the return passage after a U-turn")
    check(abs((outBack.bearing(at:back.progress) ?? 0)-180)<1 || abs((outBack.bearing(at:back.progress) ?? 0)+180)<1,"route bearing follows the selected passage")
}
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

    let turnEnd=MotorPoint(lat:p.lat+400.0/111320,lng:p.lng)
    let nearTurn = MotorRoute(request:MotorRequest(start:p,end:turnEnd),points:[p,turnEnd],
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

do {
    func p(_ n:Double,_ e:Double=0)->MotorPoint {MotorPoint(lat:30+n/111320,lng:104+e/(111320*cos(30 * Double.pi/180)))}
    func live(_ point:MotorPoint,_ course:Double=0,_ accuracy:Double=5)->CLLocation {
        CLLocation(coordinate:CLLocationCoordinate2D(latitude:point.lat,longitude:point.lng),altitude:0,
            horizontalAccuracy:accuracy,verticalAccuracy:5,course:course,courseAccuracy:5,speed:6,speedAccuracy:1,timestamp:Date())
    }
    let points=[p(0),p(100),p(100,-100),p(200,-100)]
    let turns=MotorRoute(request:MotorRequest(start:points[0],end:points[3]),points:points,steps:[
        MotorStep(instruction:"沿甲路行驶800米左转",road:"甲路",action:"左转",end:1,start:0,distance:800),
        MotorStep(instruction:"沿乙路行驶900米右转",road:"乙路",action:"右转",end:2,start:1,distance:900),
        MotorStep(instruction:"到达终点",road:"丙路",action:"到达",end:3,start:2,distance:100)
    ],seconds:100)
    Speech.shared.messages=[];MotorRoutes.mode = .failure
    session.start(turns,simulate:false)
    let calls=MotorRoutes.calls
    session.onFix(live(p(40)))
    check(session.turnMetres==60 && session.turnDirection=="L","real session measures remaining geometry rather than the supplied 800m length")
    check(Speech.shared.messages==["前方60米，左转"] && !session.instruction.contains("800"),"voice and banner contain no fixed-length provider prose")
    spin(1);session.onFix(live(p(98)))
    check(session.turnDirection=="L","next right turn is not displayed before completing the left turn")
    spin(1);session.onFix(live(p(100,-12),270))
    check(session.turnDirection=="L","one outgoing fix cannot advance the maneuver")
    spin(1);session.onFix(live(p(100,-18),270))
    check(session.turnDirection=="R" && abs(session.turnMetres-82)<=1,"two outgoing fixes advance to the next turn with fresh remaining distance")
    check(session.route?.id==turns.id && MotorRoutes.calls==calls,"following the left turn neither changes the polyline nor silently replans")
    session.stop()

    let terminal=MotorRoute(request:MotorRequest(start:p(0),end:p(1000)),points:[p(0),p(1000)],
        steps:[MotorStep(instruction:"到达终点",road:"园区入口",action:"到达",end:1,distance:1000)],seconds:120)
    session.start(terminal,simulate:false);session.onFix(live(p(940),0,35))
    MotorRoutes.mode = .suspend;session.replan(p(940));spin(0.2)
    check(busy(session),"fixture has an in-flight route before arrival candidate")
    let beforeArrival=MotorRoutes.calls
    spin(1);session.onFix(live(p(992,6),0,35))
    check(session.arrivalCandidate && !busy(session),"entering terminal zone cancels normal rerouting")
    let pending=MotorRoutes.waiting.removeFirst();pending.resume(returning:[newRoute]);spin(0.1)
    check(session.route?.id==terminal.id,"late route result cannot replace a terminal candidate")
    spin(1);session.onFix(live(p(1000,37),90,8))
    check(session.arrivalCandidate && !session.arrived,"turning inside the site keeps the terminal candidate")
    spin(1);session.onFix(live(p(1000,41),90,8))
    check(session.arrived && !session.running && MotorRoutes.calls==beforeArrival,"arrival completes despite a few remaining meters and never requests a U-turn back")
    let completedCalls=MotorRoutes.calls
    session.onFix(live(p(1100,80),90,8))
    check(MotorRoutes.calls==completedCalls && session.arrived,"completed trip cannot be reopened by later fixes")
    session.stop()

    let dynamic=MotorRequest(start:MotorPoint(lat:30,lng:104,name:"我的位置"),end:p(1000),startFromCurrentLocation:true)
    let planner=IndependentPlanner()
    planner.load(SavedMotorPlan(date:Date(),request:dynamic,distance:1000,seconds:120))
    check(planner.start==nil,"history keeps dynamic current-location semantics")
    LocationService.shared.location=live(p(500))
    MotorRoutes.mode = .success;MotorRoutes.answer=terminal
    planner.plan(.motorcycle);spin(0.2)
    check(MotorRoutes.requests.last?.start.lat==p(500).lat && MotorRoutes.requests.last?.usesCurrentLocation==true,
        "planning after moving resolves the current fix instead of reusing the old origin")
    var manual=dynamic;manual.start=p(100);manual.startFromCurrentLocation=false
    planner.load(SavedMotorPlan(date:Date(),request:manual,distance:900,seconds:100))
    planner.plan(.motorcycle);spin(0.2)
    check(MotorRoutes.requests.last?.start.lat==p(100).lat && MotorRoutes.requests.last?.usesCurrentLocation==false,
        "explicit fixed origins remain fixed")
    planner.invalidate();LocationService.shared.location=nil
    print("PASS production session: actual turn distances, left/right phases, terminal reroute suppression, arrival lock and fresh dynamic origin")
}
