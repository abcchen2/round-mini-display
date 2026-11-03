import Foundation
import Combine
import ObjectiveC

/// Uses a silent calculation only for static cameras. Never starts the driving engine.
final class WebRouteMetadata: NSObject, ObservableObject {
    static let shared=WebRouteMetadata()
    struct Camera { let point: MotorPoint; let along: Double; let speed: Int; let icon: Int }
    /// 沿途红绿灯：along 是它在**当前导航路线**上离起点的米数，播报和小地图都用这个。
    struct Light { let point: MotorPoint; let along: Double }
    @Published private(set) var status=""
    private var query: MetadataQuery?
    private var generation=UUID(), routeID: UUID?
    private var cameras: [Camera]=[]
    private var lamps: [Light]=[]
    private var lastMap="",lastLimit=""
    private let worker=DispatchQueue(label:"motonav.web-camera-match",qos:.utility)
    private var work: DispatchWorkItem?

    /// 播报用：升序的沿途距离（米），随 lamps 一起在主线程更新
    private(set) var lampDistances: [Double] = []
    /// 小地图用：高德坐标
    func lampCoords() -> [(lat: Double, lng: Double)] { lamps.map { (lat: $0.point.lat, lng: $0.point.lng) } }

    private func apply(lamps rows: [Light]) {
        lamps=rows;lampDistances=rows.map{$0.along}
    }

    func stop() {
        generation=UUID();routeID=nil;query?.cancel();query=nil;work?.cancel();work=nil
        cameras=[];apply(lamps:[]);status="";lastMap="";lastLimit=""
        BleLink.shared.send("#c");BleLink.shared.send("#k")
    }
    func load(_ route: MotorRoute) {
        stop()
        guard !route.request.bicycle else { return }
        routeID=route.id;let token=generation
        guard NaviBridge.shared.releaseForWebMetadata() else { status="电子眼未加载：其他导航正在使用引擎";return }
        status="正在核对沿途电子眼"
        query=MetadataQuery(route:route) { [weak self] result in
            guard let self=self,self.generation==token,self.routeID==route.id else { return }
            switch result {
            case .failure(let error): self.status="电子眼暂不可用：\(error.localizedDescription)"
            case .success(let data):
                let job=DispatchWorkItem { [weak self] in
                    guard let self=self else { return }
                    let target=RouteShape(points:route.points,roads:route.segmentRoads)
                    let source=RouteShape(points:data.points,roads:data.roads)
                    var found: [Camera]=[]
                    for item in data.cameras {
                        guard let p=RouteShape.unique(source.projections(item.point)),p.segment<data.roads.count else { continue }
                        let road=data.roads[p.segment],back=source.at(max(0,p.along-25))
                        guard let matched=target.match(item.point,back:back,road:road) else { continue }
                        if found.contains(where:{$0.icon==item.icon && $0.speed==item.speed && RouteShape.metres($0.point,item.point)<3 && abs($0.along-matched.along)<8}) { continue }
                        found.append(Camera(point:item.point,along:matched.along,speed:item.speed,icon:item.icon))
                    }
                    let matched=found.sorted{$0.along<$1.along}
                    // 红绿灯和电子眼走同一套投影，只是它落在无名小段上的比例更高
                    var raw: [Light]=[]
                    for item in data.lights {
                        guard let p=RouteShape.unique(source.projections(item)),p.segment<data.roads.count else { continue }
                        let road=data.roads[p.segment],back=source.at(max(0,p.along-25))
                        guard let hit = (road.isEmpty ? target.match(item,back:back) : target.match(item,back:back,road:road)) else { continue }
                        raw.append(Light(point:item,along:hit.along))
                    }
                    var rows: [Light]=[]
                    for lamp in raw.sorted(by:{$0.along<$1.along}) {
                        if let last=rows.last,lamp.along-last.along<15 { continue }   // 同一路口高德常给多个 link
                        rows.append(lamp)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self=self,self.generation==token,self.routeID==route.id,WebMotorSession.shared.route?.id==route.id,WebMotorSession.shared.running else { return }
                        self.cameras=matched;self.apply(lamps:rows)
                        self.status=rows.isEmpty ? "已核对 \(matched.count) 个电子眼" : "已核对 \(matched.count) 个电子眼、\(rows.count) 个红绿灯"
                    }
                }
                self.work=job;self.worker.async(execute:job)
            }
        }
        query?.start()
    }
    func push(route: MotorRoute, progress: Double, fresh: Bool, speed: Int) {
        let visible=fresh && routeID==route.id ? Array(cameras.filter{$0.along>=progress && $0.along-progress<=1000}.prefix(10)) : []
        var packet="#c"
        if let f=MapFeeder.shared.frame,!visible.isEmpty {
            packet+=",\(f.id)"
            for c in visible {
                if let p=MapFeeder.shared.toFrame(c.point.lat,c.point.lng) { packet+=",\(p.x),\(p.y),\(c.speed),\(c.icon)" }
            }
        }
        if packet != lastMap { lastMap=packet;BleLink.shared.send(packet) }
        let range=min(1000,max(500,Double(speed)/3.6*20))
        let nearest=visible.first{$0.speed>0 && $0.along-progress<=range}
        let limit=nearest.map{"#k,\($0.speed),\(Int(max(0,$0.along-progress)).roundedToTen)"} ?? "#k"
        if limit != lastLimit { lastLimit=limit;BleLink.shared.send(limit) }
    }
}

private extension Int { var roundedToTen: Int { ((self+5)/10)*10 } }

private final class MetadataQuery: NSObject {
    struct Point { let point: MotorPoint; let speed: Int; let icon: Int }
    struct DataSet { let points: [MotorPoint]; let roads: [String]; let cameras: [Point]; let lights: [MotorPoint] }
    private let route: MotorRoute
    private var completion: ((Result<DataSet,Error>)->Void)?
    private var timeout: DispatchWorkItem?
    private var attempts=0
    private let manager=AMapNaviDriveManager.sharedInstance()
    init(route: MotorRoute, completion: @escaping (Result<DataSet,Error>)->Void) {
        self.route=route;self.completion=completion;super.init()
        class_addProtocol(MetadataQuery.self,AMapNaviDriveManagerDelegate.self)
    }
    func start() {
        manager.delegate=(self as AnyObject) as? AMapNaviDriveManagerDelegate
        manager.isUseInternalTTS=false
        submit()
        let work=DispatchWorkItem { [weak self] in self?.finish(.failure(AmapShare.Fail("查询超时"))) }
        timeout=work;DispatchQueue.main.asyncAfter(deadline:.now()+35,execute:work)
    }
    private func submit() {
        guard completion != nil, attempts<3 else { return };attempts+=1
        guard let a=AMapNaviPoint.location(withLatitude:CGFloat(route.request.start.lat),longitude:CGFloat(route.request.start.lng)),let b=AMapNaviPoint.location(withLatitude:CGFloat(route.request.end.lat),longitude:CGFloat(route.request.end.lng)) else { finish(.failure(AmapShare.Fail("起终点无效")));return }
        let vias=RouteShape(points:route.points).anchors().compactMap{AMapNaviPoint.location(withLatitude:CGFloat($0.lat),longitude:CGFloat($0.lng))}
        let ok=manager.calculateDriveRoute(withStart:[a],end:[b],wayPoints:vias,drivingStrategy:ConvertDrivingPreferenceToDrivingStrategy(false,false,false,false,false))
        if !ok { retry() }
    }
    private func retry() {
        if attempts>=3 { finish(.failure(AmapShare.Fail("查询暂未就绪")));return }
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in self?.submit() }
    }
    func cancel() {
        completion=nil;timeout?.cancel();timeout=nil
        if manager.delegate as AnyObject? === self { manager.delegate=nil }
    }
    private func finish(_ result: Result<DataSet,Error>) {
        guard let callback=completion else { return };cancel();callback(result)
    }
    @objc(driveManagerOnCalculateRouteSuccess:)
    func successOld(_ manager: AMapNaviDriveManager) { success(manager) }
    @objc(driveManager:onCalculateRouteSuccessWithType:)
    func successNew(_ manager: AMapNaviDriveManager,type:Int) { success(manager) }
    private func success(_ manager: AMapNaviDriveManager) {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.success(manager) };return }
        guard completion != nil,let r=manager.naviRoute,
              RouteShape.metres(MotorPoint(lat:Double(r.routeEndPoint.latitude),lng:Double(r.routeEndPoint.longitude)),route.request.end)<100,
              RouteShape.metres(MotorPoint(lat:Double(r.routeStartPoint.latitude),lng:Double(r.routeStartPoint.longitude)),route.request.start)<100 else { return }
        var points: [MotorPoint]=[],roads: [String]=[],lamps: [MotorPoint]=[]
        for segment in r.routeSegments { for link in segment.links {
            // 红绿灯挂在 link 上：整个 link 都没有灯时 isHadTrafficLights 为 false
            if link.isHadTrafficLights, let end=link.coordinates.last {
                lamps.append(MotorPoint(lat:Double(end.latitude),lng:Double(end.longitude)))
            }
            for p in link.coordinates {
                let next=MotorPoint(lat:Double(p.latitude),lng:Double(p.longitude))
                if let previous=points.last,RouteShape.metres(previous,next)<0.01 { continue }
                if !points.isEmpty { roads.append(link.roadName ?? "") };points.append(next)
            }
        } }
        // 高德直接给点位时优先用它（比 link 端点更准）
        if let given=r.routeTrafficLights, !given.isEmpty {
            lamps=given.map{MotorPoint(lat:Double($0.latitude),lng:Double($0.longitude))}
        }
        let cameras=(r.routeCameras ?? []).compactMap { c -> Point? in
            guard let p=c.coordinate else { return nil }
            return Point(point:MotorPoint(lat:Double(p.latitude),lng:Double(p.longitude)),speed:max(0,c.cameraSpeed),icon:NaviBridge.camIcon(c.cameraType.rawValue))
        }
        finish(.success(DataSet(points:points,roads:roads,cameras:cameras,lights:lamps)))
    }
    @objc(driveManager:onCalculateRouteFailure:)
    func failed(_ manager: AMapNaviDriveManager,error:NSError?) {
        if Thread.isMainThread {retry()}else{DispatchQueue.main.async{[weak self] in self?.retry()}}
    }
}
