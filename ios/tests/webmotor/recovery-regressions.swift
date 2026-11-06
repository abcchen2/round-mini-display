// Long outages must recover without accepting isolated teleports or inventing loop progress.
do {
    let origin=MotorPoint(lat:30,lng:104)
    let straight=RouteShape(points:[origin,MotorPoint(lat:30+12000.0/111320,lng:104)])
    var tunnel=MotorRouteTracker(straight.points)
    precondition(tunnel.update(origin,accuracy:5,now:0) != nil)
    precondition(tunnel.update(straight.at(4000),accuracy:5,now:100) == nil)
    let resumed=tunnel.update(straight.at(4020),accuracy:5,now:101)!
    precondition(abs(resumed.progress-4020)<1 && !resumed.arrived && !resumed.needsReplan)
    precondition(tunnel.update(straight.at(4050),accuracy:5,now:102)!.progress>4049)

    var jump=MotorRouteTracker(straight.points)
    _=jump.update(origin,accuracy:5,now:0)
    precondition(jump.update(straight.at(4000),accuracy:5,now:1)==nil)
    precondition(jump.update(straight.at(4000),accuracy:5,now:100)==nil)
    precondition(jump.update(straight.at(10),accuracy:5,now:101)!.progress<11)
    precondition(jump.update(straight.at(30),accuracy:5,now:102)!.progress<31)

    let vertex=RouteShape(points:[origin,straight.at(4000),straight.at(8000)])
    var sharedVertex=MotorRouteTracker(vertex.points)
    _=sharedVertex.update(origin,accuracy:5,now:0)
    precondition(sharedVertex.update(vertex.at(4000),accuracy:5,now:100)==nil)
    precondition(sharedVertex.update(vertex.at(4000),accuracy:5,now:101)!.progress>3999)

    let loop=[origin,straight.at(8000),origin,straight.at(8000)]
    var ambiguous=MotorRouteTracker(loop)
    _=ambiguous.update(origin,accuracy:5,now:0)
    precondition(ambiguous.update(straight.at(4000),accuracy:5,now:400)==nil)
    let uncertain=ambiguous.update(straight.at(4020),accuracy:5,now:401)!
    precondition(uncertain.needsReplan && uncertain.progress<1 && !uncertain.arrived)
    for i in 1...12 {
        let held=ambiguous.update(straight.at(4020+Double(i)*10),accuracy:5,now:401+Double(i))!
        precondition(held.needsReplan && held.progress<1 && !held.arrived)
    }

    var staleCandidate=MotorRouteTracker(straight.points)
    _=staleCandidate.update(origin,accuracy:5,now:0)
    precondition(staleCandidate.update(straight.at(4000),accuracy:5,now:100)==nil)
    precondition(staleCandidate.update(straight.at(6000),accuracy:5,now:101)==nil)
    precondition(staleCandidate.update(straight.at(6010),accuracy:70,now:102)==nil)
    precondition(staleCandidate.update(straight.at(6010),accuracy:5,now:110)==nil)
    precondition(staleCandidate.update(straight.at(6020),accuracy:5,now:111)!.progress>6019)

    var finish=MotorRouteTracker(vertex.points)
    _=finish.update(origin,accuracy:5,now:0)
    precondition(finish.update(vertex.at(7960),accuracy:5,now:200)==nil)
    precondition(!finish.update(vertex.at(7960),accuracy:5,now:201)!.arrived)
    precondition(!finish.update(vertex.at(7985),accuracy:5,now:202)!.arrived)
    precondition(!finish.update(vertex.at(7995),accuracy:5,now:203)!.arrived)
    precondition(finish.update(vertex.at(8000),accuracy:5,now:204)!.arrived)
    print("PASS long GPS outage: consistent recovery, teleport rejection, shared vertices, ambiguous loops, stale candidates and terminal dwell")

    let points=[origin,straight.at(100),straight.at(200)]
    let share=AmapShare.Route(startName:"start",startLat:origin.lat,startLng:origin.lng,
        endName:"end",endLat:points[2].lat,endLng:points[2].lng,
        pts:points.map{($0.lat,$0.lng)},roads:[
            .init(name:"左家庄路",length:100,pts:points.prefix(2).map{($0.lat,$0.lng)}),
            .init(name:"右安门路",length:100,pts:points.suffix(2).map{($0.lat,$0.lng)})
        ],distance:200,timeS:60,lights:0,restored:true,kind:"摩托车")
    let imported=MotorRoutes.fromShare(share)
    precondition(!imported.detailedGuidance && imported.steps.allSatisfy{$0.action.isEmpty})
    precondition(imported.steps.map{$0.start} == [0,1] && imported.steps.map{$0.end} == [1,2])
    precondition(imported.segmentRoads == ["左家庄路","右安门路"])
    precondition(imported.points.count==3 && imported.steps[0].instruction=="左家庄路")
    print("PASS shared route: road names cannot become turn actions, ordered segment ranges and geometry preserved")
}
