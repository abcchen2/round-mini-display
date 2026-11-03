import com.yuminaga.motonav.ProviderEngineState;
import com.yuminaga.motonav.ProviderStartup;

public final class ProviderEngineStateTest {
    static void check(boolean v,String s){if(!v)throw new AssertionError(s);}
    public static void main(String[] args){
        ProviderEngineState e=new ProviderEngineState();e.reset(1000);
        check(e.accept(1000,1100,false,false,1100),"planned route state received");
        check(!e.realStarted(1050,1100),"planned route/guide must not acknowledge navigation");
        check(!e.accept(999,1200,true,false,1200),"old session cannot acknowledge");
        check(!e.accept(1000,8000,true,false,1200),"future state rejected");
        e.accept(1000,1300,true,false,1300);
        check(!e.realStarted(1250,1300),"one native poll is not a stable start");
        e.accept(1000,2300,true,false,2300);
        check(e.realStarted(1250,2300),"actual native navigation acknowledged without GPS guide updates");
        check(!e.realStarted(1250,5001),"stale native state cannot confirm a start");
        e.accept(1000,5100,true,true,5100);
        check(!e.realStarted(1250,5100),"simulation is not real guidance");
        e.accept(1000,6000,false,false,6000);e.accept(1000,7000,false,false,7000);
        check(!e.stopped(7000),"brief transition must not restart a route");
        e.accept(1000,9000,false,false,9000);check(e.stopped(9000),"fresh sustained stop is visible");
        check(!e.stopped(12000),"lost heartbeat is not a confirmed stop");
        e.reset(13000);check(!e.realStarted(13001,13001),"new session clears old state");

        ProviderStartup s=new ProviderStartup();s.begin(1000);
        s.next(1000,false,false);s.next(2000,true,false);s.calculated();s.next(3000,true,false);
        s.next(5000,true,true);check(s.running(),"started");
        check(s.next(100000,true,false)==ProviderStartup.NONE,"stationary silence does not restart");
        check(s.recoverStoppedEngine(100001),"confirmed stop permits first recovery");
        check(s.next(100001,true,false)==ProviderStartup.WARM,"recovery warms before replanning");
        s.next(100002,true,false);s.calculated();s.next(100003,true,false);s.next(100004,true,true);
        check(s.recoverStoppedEngine(200000),"second recovery permitted");
        s.next(200000,true,false);s.next(200001,true,false);s.calculated();s.next(200002,true,false);s.next(200003,true,true);
        check(!s.recoverStoppedEngine(300000),"recovery is bounded");
        s.stop();check(!s.recoverStoppedEngine(300001),"ending navigation disables recovery");
        System.out.println("Provider engine acknowledgement and bounded recovery passed");
    }
}
