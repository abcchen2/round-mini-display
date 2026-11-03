#pragma once
#include "../../RasterWork.h"

RasterWork pendingRasterWork;
int pendingRasterId=-1,pendingRasterTheme=-1;
uint32_t pendingRasterEpoch=0;
bool pendingRasterKeep=false,pendingRasterCarry=false;

void cancelPendingRaster() {
  if(pendingRasterWork.active) {
    Bulk &b=bulks[3];
    if(b.id==pendingRasterId){b.done=false;b.got=0;memset(b.mask,0,sizeof(b.mask));}
  }
  rasterWorkCancel(pendingRasterWork);
}
bool queueRasterWork(const uint8_t *p,uint32_t len,int id) {
  RasterHeader next;
  if(!rasterCheck(p,len,next,RASTER_MAX_PX,RASTER_BUF_BYTES))return false;
  if(next.dataEnd!=len)return parseRaster(p,len); // Existing optional geometry extension.
  if(!rasterBackBuf)rasterBackBuf=(uint8_t *)ps_malloc(RASTER_BUF_BYTES);
  if(!rasterBackBuf)return false;
  RasterHeader old=currentRasterHeader();
  pendingRasterKeep=canKeepRaster(old,next);
  pendingRasterId=id;pendingRasterTheme=themeIdx;
  pendingRasterEpoch=mediaConnectionEpoch;pendingRasterCarry=rasterBuildingCarryOn;
  // The back map is now work-in-progress. Keep drawing the untouched front.
  rasterBackValid=false;
  rasterWorkBegin(pendingRasterWork,p,next,rasterBackBuf,rasterBuf,old,
                  pendingRasterKeep && rasterBuildingCarryOn && themeIdx==1);
  return true;
}
void pollRasterWork() {
  if(!pendingRasterWork.active)return;
  Bulk &b=bulks[3];
  if(!bleConnected || !bleAuthed || pendingRasterEpoch!=mediaConnectionEpoch ||
     b.id!=pendingRasterId || b.buf!=pendingRasterWork.packet ||
     pendingRasterTheme!=themeIdx || pendingRasterCarry!=rasterBuildingCarryOn) {
    cancelPendingRaster();return;
  }
  const uint32_t started=micros();
  do {
    if(rasterWorkStep(pendingRasterWork)) {
      installDecodedRaster(pendingRasterWork.packet,pendingRasterWork.next,pendingRasterWork.old,pendingRasterKeep);
      b.done=true;pendingAck="K,3,"+String(pendingRasterId);navDirty=true;
      rasterWorkCancel(pendingRasterWork);
      return;
    }
  } while((uint32_t)(micros()-started)<16000);
}
