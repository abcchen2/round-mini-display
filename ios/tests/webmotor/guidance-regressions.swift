// AMap geometry remains GCJ-02; live guidance does not reuse fixed-distance route prose.
do {
    func p(_ n:Double,_ e:Double=0)->MotorPoint {
        MotorPoint(lat:30+n/111320,lng:104+e/(111320*cos(30 * Double.pi/180)))
    }
    let points=[p(0),p(100),p(100,-100),p(200,-100)]
    let route=MotorRoute(request:MotorRequest(start:points[0],end:points[3]),points:points,steps:[
        MotorStep(instruction:"沿甲路行驶800米左转",road:"甲路",action:"左转",end:1,start:0,distance:800),
        MotorStep(instruction:"沿乙路行驶900米右转",road:"乙路",action:"右转",end:2,start:1,distance:900),
        MotorStep(instruction:"到达目的地",road:"丙路",action:"到达",end:3,start:2,distance:100)
    ],seconds:100)
    precondition(MotorGuidance.remaining(to:route.steps[0],route:route,progress:40)==60)
    precondition(MotorGuidance.spoken(route.steps[0],distance:60)=="前方60米，左转")
    precondition(!MotorGuidance.instruction(route.steps[0]).contains("800"))
    precondition(MotorStep(instruction:"",road:"",action:"左转调头",end:1).dir=="U")

    var state=MotorStepProgress()
    precondition(state.update(route:route,progress:98,point:p(98),accuracy:15,heading:0,now:0,simulation:false)==0)
    precondition(state.update(route:route,progress:109,point:p(98),accuracy:15,heading:0,now:1,simulation:false)==0,
        "Longitudinal progress jitter before the corner must not expose the next right turn")
    precondition(state.update(route:route,progress:112,point:p(100,-12),accuracy:15,heading:270,now:2,simulation:false)==0)
    precondition(state.update(route:route,progress:118,point:p(100,-18),accuracy:15,heading:270,now:3,simulation:false)==1)
    precondition(MotorGuidance.remaining(to:route.steps[state.index],route:route,progress:118)==82)
    precondition(state.update(route:route,progress:118,point:p(100,-4),accuracy:15,heading:nil,now:4,simulation:false)==1)
    precondition(state.update(route:route,progress:199,point:p(100,-99),accuracy:15,heading:270,now:5,simulation:false)==1)
    precondition(state.update(route:route,progress:212,point:p(112,-100),accuracy:15,heading:0,now:6,simulation:false)==1)
    precondition(state.update(route:route,progress:219,point:p(119,-100),accuracy:15,heading:0,now:7,simulation:false)==2)
    var noise=MotorStepProgress()
    for i in 0...3 {
        precondition(noise.update(route:route,progress:107,point:p(100,-7),accuracy:20,heading:nil,now:Double(i),simulation:false)==0)
    }
    let shallow=MotorRoute(request:route.request,points:[p(0),p(100),p(200,-100),p(300,-100)],steps:route.steps,seconds:100)
    var straightThrough=MotorStepProgress()
    precondition(straightThrough.update(route:shallow,progress:108.5,point:p(112),accuracy:5,heading:0,now:0,simulation:false)==0)
    precondition(straightThrough.update(route:shallow,progress:111.3,point:p(116),accuracy:5,heading:0,now:1,simulation:false)==0,
        "Continuing straight beside a shallow left branch is not evidence of a left turn")
    print("PASS live maneuver distance/text and confirmed left-then-right transitions with junction jitter")

    let destination=p(300,100)
    func alternative(_ middle:MotorPoint,_ seconds:Int)->MotorRoute {
        MotorRoute(request:MotorRequest(start:p(0),end:destination),points:[p(0),middle,destination],
            steps:[MotorStep(instruction:"",road:"",action:"",end:2)],seconds:seconds)
    }
    let reverse=alternative(p(-100),100),forward=alternative(p(100),110),expensive=alternative(p(100),400)
    precondition(MotorRouteSelection.preferred([reverse,forward],from:p(0),heading:0)?.id==forward.id)
    precondition(MotorRouteSelection.preferred([reverse,forward],from:p(0),heading:nil)?.id==reverse.id)
    precondition(MotorRouteSelection.preferred([reverse,expensive],from:p(0),heading:0)?.id==reverse.id)
    precondition(MotorRouteSelection.preferred([reverse,reverse],from:p(0),heading:0)?.id==reverse.id)
    let folded=MotorRoute(request:reverse.request,points:[p(0),p(20),p(0),p(-100),destination],steps:reverse.steps,seconds:100)
    precondition(MotorRouteSelection.preferred([folded,forward],from:p(0),heading:0)?.id==folded.id)
    precondition(MotorGuidance.reliableHeading(speed:8,course:0,courseAccuracy:-1,accuracy:5)==nil)
    precondition(MotorGuidance.reliableHeading(speed:2,course:0,courseAccuracy:5,accuracy:5)==nil)
    precondition(MotorGuidance.reliableHeading(speed:8,course:0,courseAccuracy:5,accuracy:40)==nil)
    precondition(MotorGuidance.reliableHeading(speed:8,course:0,courseAccuracy:5,accuracy:5)==0)
    precondition(forward.points[1].lat==p(100).lat,"Selection cannot mutate the provider's polyline")
    print("PASS conservative AMap alternative selection, known heading quality and U-shaped departure rejection")

    let dynamic=MotorRequest(start:MotorPoint(lat:30,lng:104,name:"我的位置"),end:destination,startFromCurrentLocation:true)
    var fields=try JSONSerialization.jsonObject(with:JSONEncoder().encode(dynamic)) as! [String:Any]
    fields.removeValue(forKey:"startFromCurrentLocation")
    let legacy=try JSONDecoder().decode(MotorRequest.self,from:JSONSerialization.data(withJSONObject:fields))
    precondition(legacy.usesCurrentLocation)
    var manual=dynamic;manual.startFromCurrentLocation=false
    precondition(!manual.usesCurrentLocation)
    let roundTrip=try JSONDecoder().decode(MotorRequest.self,from:JSONEncoder().encode(dynamic))
    precondition(roundTrip.usesCurrentLocation)
    print("PASS dynamic-current-location origin and legacy saved-plan compatibility")

    let disconnected="""
    {"code":1,"data":[{"steps":[{"polyline":"104,30;104,30.001"},{"polyline":"104,30.01;104,30.011"}]}]}
    """
    expectFailure{_ = try MotorRoutes.parse(Data(disconnected.utf8),request:req)}
    let alternatives="""
    {"code":1,"data":[{"steps":[{"polyline":"104,30;104,30.001"},{"polyline":"104,30.01;104,30.011"}]},{"steps":[{"polyline":"104,30;104,30.001"}]}]}
    """
    let usable=try MotorRoutes.parse(Data(alternatives.utf8),request:req)
    precondition(usable.count==1)
    print("PASS disconnected route rejection without discarding a valid AMap alternative")

    let wgs=MotorPoint(lat:39.908823,lng:116.397470)
    let gcj=MapGeo.wgsToGcj(wgs.lat,wgs.lng),restored=MapGeo.gcjToWgs(gcj.lat,gcj.lng)
    precondition(RouteShape.metres(wgs,MotorPoint(lat:gcj.lat,lng:gcj.lng))>100)
    precondition(RouteShape.metres(wgs,MotorPoint(lat:restored.lat,lng:restored.lng))<1)
    let gcjPoints=[MotorPoint(lat:gcj.lat,lng:gcj.lng),MotorPoint(lat:gcj.lat+0.001,lng:gcj.lng)]
    let unchanged=MotorRoute(request:MotorRequest(start:gcjPoints[0],end:gcjPoints[1]),points:gcjPoints,steps:[MotorStep(instruction:"",road:"",action:"",end:1)],seconds:10)
    precondition(unchanged.at(0).lat==gcj.lat && unchanged.at(0).lng==gcj.lng)
    print("PASS existing WGS-84/GCJ-02 boundary conversion and unmodified AMap route coordinates")
}
