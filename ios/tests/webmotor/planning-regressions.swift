// Run production announcement state and parser error handling without network/account data.
do {
    var turns = MotorAnnouncementGate()
    let distances = [600, 500, 498, 201, 200, 199, 202, 198, 150, 0]
    let spoken = distances.compactMap { turns.take(event:0,distance:$0,gates:[500,200]) }
    precondition(spoken == [500,200], "GPS jitter cannot replay an old gate")
    precondition(turns.take(event:1,distance:150,gates:[500,200]) == 200)
    for _ in 0..<1000 {
        precondition(turns.take(event:1,distance:150,gates:[500,200]) == nil)
    }
    precondition(turns.take(event:2,distance:-1,gates:[300,60]) == nil)
    precondition(turns.take(event:2,distance:40,gates:[300,60]) == 60)
    precondition(turns.take(event:2,distance:80,gates:[300,60]) == nil)

    func failure(_ text: String) -> String {
        do { _ = try MotorRoutes.parse(Data(text.utf8),request:req); fatalError("failure accepted") }
        catch { return error.localizedDescription }
    }
    for text in ["{}", "<html>service unavailable</html>", "{\"code\":1,\"data\":[]}",
                 "{\"code\":0,\"msg\":\"no route\"}", "{\"code\":1,\"data\":{}}"] {
        let message = failure(text)
        precondition(!message.contains("登录") && !message.contains("验证"), "generic failures are not login failures")
    }
    precondition(failure("{\"code\":0,\"msg\":\"请先登录\"}").contains("要求登录"))
    precondition(failure("{\"code\":0,\"message\":\"安全验证\"}").contains("要求网页验证"))
    let safe = failure("{\"code\":9876,\"msg\":\"private-account https://example.com/?token=secret\"}")
    precondition(safe.contains("服务代码：9876") && !safe.contains("private-account") && !safe.contains("token"))
    for code in [1002,1003,1008,1009,1012,-1009,0] {
        let message = BicycleRouteParser.failureMessage(code:code)
        precondition(message.contains("错误码：\(code)") && !message.contains("登录"))
    }
    print("PASS monotonic speech gates, route-error classification, safe service codes and bicycle errors")
}
