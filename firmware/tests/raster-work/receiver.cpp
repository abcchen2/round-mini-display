#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>
#include "fixture/RasterWork.h"

static int checks=0;
static void check(bool ok,const char *why){++checks;if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
static std::string String(int n){return std::to_string(n);}
static int32_t rd32(const uint8_t *p){return rasterI32(p);}
struct Bulk {int id=-1,parts=0,got=0;uint32_t total=0,cap=400000;bool done=false;uint8_t *buf=nullptr;uint8_t mask[512]={};};
Bulk bulks[5];
std::string pendingAck;
constexpr size_t RASTER_BUF_BYTES=720000;
constexpr uint32_t RASTER_MAX_PX=1440000;
bool rasterBackValid=true,rasterBuildingCarryOn=true,bleConnected=true,bleAuthed=true,navDirty=false;
int themeIdx=1,installed=0,routeCalls=0;
uint32_t mediaConnectionEpoch=1,ticks=0;
uint8_t *rasterBuf=nullptr,*rasterBackBuf=nullptr,*mapShow=nullptr;
RasterHeader visible={};
static uint32_t micros(){return ticks+=1000;}
static void *ps_malloc(size_t n){return malloc(n);}
static RasterHeader currentRasterHeader(){return visible;}
static bool canKeepRaster(const RasterHeader &old,const RasterHeader &next){return old.frame==next.frame&&old.mm==next.mm&&!next.palette;}
static void installDecodedRaster(const uint8_t *,const RasterHeader &next,const RasterHeader &,bool){std::swap(rasterBuf,rasterBackBuf);visible=next;rasterBackValid=true;++installed;}
static bool parseRaster(const uint8_t *,uint32_t){return false;}
static void parseMap(const uint8_t *,uint32_t){}
static void parseRoute(const uint8_t *,uint32_t){++routeCalls;}
static void parseGhost(const uint8_t *,uint32_t){}
#include "fixture/src/map/RasterWorkQueue.h"
#include "fixture/src/protocol/BulkReceiver.h"
static void put(std::vector<uint8_t>&p,int at,uint32_t v,int bytes){for(int k=0;k<bytes;k++)p[at+k]=(v>>(k*8))&255;}
static std::vector<uint8_t> packet(int x=0){
 std::vector<uint8_t>p(16);put(p,0,73,2);put(p,2,x,4);put(p,6,0,4);put(p,10,1200,2);put(p,12,1200,2);put(p,14,2000,2);
 for(int remain=1440000;remain;){int n=std::min(remain,271);if(n<=15)p.push_back((n-1)<<4);else{p.push_back(240);p.push_back(n-16);}remain-=n;}return p;
}
static std::vector<uint8_t> send(const std::vector<uint8_t>&p,int id,int type=3,int payload=485){
 std::vector<uint8_t>last;int parts=(p.size()+payload-1)/payload;
 for(int seq=0;seq<parts;seq++){
  int off=seq*payload,len=std::min<int>(payload,p.size()-off);std::vector<uint8_t>d(15+len);
  d[0]='M';d[1]=type;d[2]=id;put(d,3,parts,2);put(d,5,seq,2);put(d,7,p.size(),4);put(d,11,off,4);memcpy(d.data()+15,p.data()+off,len);
  handleBulk(d.data(),d.size());last=d;
 }return last;
}
int main(){
 std::vector<uint8_t>a(720000,0x44),b(720000,0xa5),packets(400000),other(400000);
 rasterBuf=a.data();rasterBackBuf=b.data();for(int kind=1;kind<=4;kind++)bulks[kind].buf=kind==3?packets.data():other.data();
 visible.frame=73;visible.width=visible.height=1200;visible.blocksWide=75;visible.bytes=720000;visible.mm=2000;visible.buildings=true;
 auto p=packet();const auto original=a;
 auto last=send(p,1);check(pendingRasterWork.active&&!bulks[3].done&&pendingAck.empty(),"complete wire packet schedules work without early ACK");
 check(!rasterBackValid&&a==original,"unfinished back map is hidden, front untouched");
 pollRasterWork();check(pendingRasterWork.active&&installed==0,"one bounded poll yields before whole full-size map finishes");
 auto cursor=pendingRasterWork.decode.emitted;
 handleBulk(last.data(),last.size());check(pendingRasterWork.decode.emitted==cursor&&pendingAck.empty()&&!bulks[3].done,"receipt probes do not restart work or falsely ACK");
 for(int limit=0;pendingRasterWork.active&&limit<1000;limit++){check(a==original,"front pixels stable throughout incremental work");pollRasterWork();}
 check(installed==1&&bulks[3].done&&pendingAck=="K,3,1","exactly one atomic commit and ACK after completion");
 check(visible.buildings&&std::all_of(b.begin(),b.end(),[](uint8_t v){return v==0x44;}),"all roofs inherited before commit");
 pendingAck.clear();handleBulk(last.data(),last.size());check(pendingAck=="K,3,1"&&installed==1,"completed duplicate repeats receipt without re-installing");
 pendingAck.clear();send(p,2);pollRasterWork();send(packet(2),3);
 check(pendingRasterId==3&&pendingRasterWork.decode.emitted==0&&!bulks[3].done,"new packet replaces incomplete job before compressed-buffer reuse");
 themeIdx=2;pollRasterWork();check(!pendingRasterWork.active&&!bulks[3].done&&bulks[3].got==0&&pendingAck.empty()&&installed==1,"style change cancels without old-map commit or ACK");themeIdx=1;
 send(p,4);++mediaConnectionEpoch;pollRasterWork();check(!pendingRasterWork.active&&installed==1,"connection epoch change cancels work");
 send(p,5);bleConnected=false;pollRasterWork();check(!pendingRasterWork.active&&installed==1,"disconnect cancels work");bleConnected=true;
 send(p,6);rasterBuildingCarryOn=false;pollRasterWork();check(!pendingRasterWork.active&&installed==1,"building preference change cancels work");rasterBuildingCarryOn=true;
 send(p,7);cancelPendingRaster();pollRasterWork();check(!pendingRasterWork.active&&bulks[3].got==0&&installed==1,"navigation reset discards incomplete job");
 p.pop_back();send(p,8);check(!pendingRasterWork.active&&!bulks[3].done&&bulks[3].got==0&&installed==1,"invalid map is retryable and never acknowledged");
 send(packet(),9,2);check(routeCalls==1&&pendingAck=="K,2,9","route packets retain original immediate ACK behavior");
 // Both current phone senders use this 15-byte header, capped at 500 bytes
 // per message. Exercise full payload and reduced-MTU fallback sizes.
 int id=10;
 for(int payload : {5,185,300,485}) {
  pendingAck.clear();int previous=installed;auto tail=send(packet(),id,3,payload);
  check(pendingRasterWork.active&&pendingAck.empty(),"phone MTU variant waits for actual decode completion");
  send(packet(),id,2,payload);pendingAck.clear();
  for(int limit=0;pendingRasterWork.active&&limit<1000;limit++)pollRasterWork();
  check(installed==previous+1&&pendingAck=="K,3,"+String(id),"phone MTU variant commits and acknowledges after interleaved route");
  pendingAck.clear();handleBulk(tail.data(),tail.size());check(pendingAck=="K,3,"+String(id),"phone MTU variant recovers a lost receipt");
  id++;
 }
 printf("PASS %d receiver checks: bounded work, atomic commit, delayed receipt, probes, packet replacement, session/style/preference cancellation and invalid-map retries\n",checks);
}
