package com.yuminaga.motonav;

/** A route calculation/guide packet is not proof that native guidance is running. */
public final class ProviderEngineState {
    private long session,at=-1,realSince=-1,stoppedSince=-1;
    private boolean real,simulation;
    public void reset(long token){session=token;at=realSince=stoppedSince=-1;real=simulation=false;}
    public boolean accept(long token,long stamp,boolean driving,boolean emulating,long now){
        if(session<=0||token!=session||stamp<session||stamp<=at||now<stamp||now-stamp>2500)return false;
        boolean contiguous=at>=0&&stamp-at<=2500;
        at=stamp;real=driving;simulation=emulating;
        if(real&&!simulation){if(!contiguous||realSince<0)realSince=stamp;stoppedSince=-1;}
        else{realSince=-1;if(!real&&!simulation){if(!contiguous||stoppedSince<0)stoppedSince=stamp;}else stoppedSince=-1;}
        return true;
    }
    public boolean fresh(long now){return at>=0&&now>=at&&now-at<=2500;}
    public boolean realStarted(long startCommand,long now){
        return startCommand>0&&fresh(now)&&real&&!simulation&&realSince>=0&&
            at-Math.max(startCommand,realSince)>=1000;
    }
    public boolean stopped(long now){return fresh(now)&&!real&&!simulation&&stoppedSince>=0&&at-stoppedSince>=3000;}
    public boolean real(){return real;}
    public boolean simulation(){return simulation;}
}
