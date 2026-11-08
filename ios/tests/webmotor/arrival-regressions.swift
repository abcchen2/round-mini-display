// Independent route arrival uses GCJ-02 fixes and the road-network endpoint.
do {
    func p(_ north:Double,_ east:Double=0)->MotorPoint {
        MotorPoint(lat:30+north/111320,lng:104+east/(111320*cos(30 * Double.pi/180)))
    }
    let road=[p(0),p(1000)]
    var gate=MotorRouteTracker(road)
    precondition(!gate.update(p(940),accuracy:35,now:0)!.arrivalCandidate)
    precondition(gate.update(p(992,6),accuracy:35,now:1)!.arrivalCandidate)
    // After passing the gate the rider turns into the site, outside the normal on-route threshold.
    let inside=gate.update(p(1000,37),accuracy:8,now:2)!
    precondition(inside.arrivalCandidate && !inside.arrived)
    let parked=gate.update(p(1000,41),accuracy:8,now:3)!
    precondition(parked.arrived && !parked.needsReplan)
    let locked=gate.update(p(5000),accuracy:5,now:180)!
    precondition(locked.arrived && !locked.needsReplan)

    var direct=MotorRouteTracker(road)
    let first=direct.update(p(996),accuracy:35,now:0)!
    precondition(first.arrivalCandidate && !first.arrived)
    precondition(!direct.update(p(996),accuracy:35,now:1)!.arrived)
    precondition(direct.update(p(997),accuracy:35,now:2)!.arrived)

    var retry=MotorRouteTracker(road)
    precondition(retry.update(p(996),accuracy:8,now:0)!.arrivalCandidate)
    let departed=retry.update(p(931),accuracy:8,now:1)!
    precondition(!departed.arrivalCandidate && !departed.arrived)
    precondition(retry.update(p(993),accuracy:8,now:2)!.arrivalCandidate)
    precondition(!retry.update(p(994),accuracy:8,now:3)!.arrived)
    precondition(retry.update(p(995),accuracy:8,now:4)!.arrived)

    var turningBack=MotorRouteTracker(road)
    precondition(turningBack.update(p(990),accuracy:5,now:0,heading:0)!.arrivalCandidate)
    let retreat=turningBack.update(p(975),accuracy:5,now:1,heading:180)!
    precondition(!retreat.arrivalCandidate && !retreat.arrived)
    let away=turningBack.update(p(960),accuracy:5,now:2,heading:180)!
    precondition(!away.arrivalCandidate && !away.arrived)

    for length in [8.0,20.0] {
        var short=MotorRouteTracker([p(0),p(length)])
        for i in 0...2 {
            precondition(!short.update(p(0),accuracy:5,now:Double(i))!.arrivalCandidate)
        }
        let nearEnd=p(length-3.5)
        precondition(short.update(nearEnd,accuracy:5,now:3)!.arrivalCandidate)
        precondition(!short.update(nearEnd,accuracy:5,now:4)!.arrived)
        precondition(short.update(nearEnd,accuracy:5,now:5)!.arrived)
    }

    var poorFix=MotorRouteTracker(road)
    precondition(poorFix.update(p(996),accuracy:8,now:0)!.arrivalCandidate)
    precondition(poorFix.update(p(996),accuracy:55,now:1)==nil)
    precondition(!poorFix.update(p(996),accuracy:8,now:2)!.arrived)
    precondition(!poorFix.update(p(996),accuracy:8,now:3)!.arrived)
    precondition(poorFix.update(p(996),accuracy:8,now:4)!.arrived)

    // Start/end overlap. Waiting at the start cannot finish a round trip.
    var loop=MotorRouteTracker([p(0),p(600),p(600,300),p(0,300),p(0)])
    for i in 0...5 {
        precondition(!loop.update(p(0),accuracy:12,now:Double(i))!.arrivalCandidate)
    }
    // An earlier eastbound overpass also crosses within 8 m of the final, northbound leg.
    // Even a fix landing on the endpoint itself cannot identify the deck on a cold start.
    var crossing=MotorRouteTracker([p(0,-500),p(0,500),p(-500,500),p(-500),p(8)])
    for i in 0...5 {
        let fix=crossing.update(p(8),accuracy:15,now:Double(i))!
        precondition(!fix.arrivalCandidate && !fix.arrived)
    }
    print("PASS terminal gate, moderate accuracy, cold start, candidate hysteresis, re-entry, grade-separated crossing, loop start and arrival latch")
}
