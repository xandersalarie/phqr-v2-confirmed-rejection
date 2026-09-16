//+------------------------------------------------------------------+
//| PHQR V2 - Confirmed Quartile Rejection                            |
//| Short-only. Closed H1/M5 signals. Deterministic and auditable.      |
//+------------------------------------------------------------------+
#property strict
#property version "2.10"
#property description "PHQR V2 - Confirmed Quartile Rejection; closed H1/M5, short only"
#include <Trade/Trade.mqh>

enum NewsFilterFailMode { NEWS_BLOCK_TRADES=0, NEWS_ALLOW_TRADES=1 };
enum ENUM_SESSION_CLOCK { SERVER_TIME=0, GMT_TIME=1 };
enum ENUM_SETUP_STATE
  {
   WAITING_FOR_NEW_H1, REFERENCE_READY, WAITING_FOR_SWEEP,
   WAITING_FOR_REJECTION, PENDING_ENTRY, POSITION_OPEN, SETUP_INVALIDATED, SETUP_FINISHED
  };
enum ENUM_FILTER_RESULT { NOT_EVALUATED=0, FILTER_PASS, FILTER_BLOCK, FILTER_DISABLED, FILTER_ERROR_ALLOW, FILTER_ERROR_BLOCK };
enum ENUM_SKIP_REASON
  {
   SKIP_NONE=0, ATR_FILTER_REJECTED, EXPANSION_FILTER_REJECTED, PREVIOUS_HIGH_BROKEN,
   SPREAD_FILTER_REJECTED, NEWS_FILTER_REJECTED, SESSION_FILTER_REJECTED, DAILY_LOSS_LIMIT,
   INVALID_QUOTES, TRADE_NOT_ALLOWED, SYMBOL_NOT_TRADEABLE, OWNERSHIP_CONFLICT,
   EXISTING_EXPOSURE, INVALID_STOPS, RR_FILTER_REJECTED, INVALID_VOLUME,
   INSUFFICIENT_MARGIN, ORDER_CHECK_FAILED, ORDER_SEND_FAILED, ORDER_SEND_UNCERTAIN,
   HISTORY_UNAVAILABLE, PERSISTENCE_FAILED, WINDOW_ENDED, NO_REJECTION, SIGNAL_NO_FILL,
   RECOVERY_NO_RETROACTIVE_ENTRY, DATA_UNAVAILABLE
  };
enum ENUM_EXIT_REASON { EXIT_NONE=0, TAKE_PROFIT, STOP_LOSS, BREAK_EVEN_EXIT, MAX_HOLD_TIME_EXIT, EXTERNAL_EXIT, STOP_OUT, ENTRY_EXPIRED, ENTRY_CANCELED, ENTRY_REJECTED };

input group "GENERAL"
input ulong MagicNumber=75025002;                 // Unique magic; use one instance per symbol/magic
input bool EnableLongStrategy=false;             // Long logic is intentionally not implemented
input ulong MaxDeviationPoints=20;               // Allowed market-exit deviation in symbol points
input int MaxOpenTrades=1;                       // Account-wide own positions + pending entries with this magic
input group "VOLATILITY"
input bool UseATRFilter=true;                    // H1 range must be within ATR multiples
input int ATRPeriod=14;                          // ATR period on CLOSED H1 candles
input double MinATRMultiple=0.65;                // Inclusive minimum reference range/ATR
input double MaxATRMultiple=1.60;                // Inclusive maximum reference range/ATR
input group "SIGNAL"
input bool UseExpansionFilter=true;              // Reject unusually strong bullish reference expansion
input double ExpansionBodyRatio=0.65;            // Inclusive minimum bullish body/range
input double ExpansionCloseLocation=0.80;        // Inclusive minimum (close-low)/range
input double SweepPercent=0.03;                  // Fraction of reference range above Q75
input double RejectionCloseLocationMax=0.50;     // Rejection must close in lower half of its own M5 range
input group "ENTRY"
input int EntryExpiryM5Bars=2;                   // New M5 bars after rejection close; also capped by H1 end
input double StopBufferPercent=0.01;             // Minimum stop buffer as fraction of reference range
input double SpreadMultiplier=1.50;              // Alternative stop buffer in current spreads
input double MinRR=1.60;                         // Minimum planned reward/risk
input group "RISK"
input double RiskPercent=0.50;                   // Percent of current account equity at original SL
input group "BREAK EVEN"
input double BreakEvenOffsetPoints=0.0;          // Short BE SL = actual entry minus this many points
input group "HOLDING"
input bool UseMaximumHoldingTime=false;          // Optional safety exit only; disabled by default
input int MaximumHoldingMinutes=180;             // Applied from actual fill time when enabled
input group "DAILY GUARD"
input bool UseDailyLossGuard=true;               // Block new entries after net realized daily R reaches the loss cap
input double MaxDailyLossR=2.0;                  // Once latched, block new entries for the rest of broker day
input group "SPREAD"
input bool UseSpreadFilter=true;                 // Check current ask-bid spread at order decision
input double MaxSpreadRangePercent=0.03;         // Maximum current spread/reference range
input group "NEWS"
input bool UseNewsFilter=true;                   // Native MT5 calendar; server time
input string NewsCurrency="USD";                // Calendar currency code
input int NewsMinutesBefore=15;                 // Block this many minutes before an event
input int NewsMinutesAfter=15;                  // Block this many minutes after an event
input NewsFilterFailMode NewsFilterFailureMode=NEWS_BLOCK_TRADES; // Live/broker calendar failure action
input bool TesterAllowTradesWithoutNewsData=true; // Tester only: native calendar is unavailable; live behavior is unchanged
input group "SESSION"
input bool UseSessionFilter=false;              // Optional entry-placement session
input int SessionStartHour=0;                    // Session start hour, inclusive
input int SessionStartMinute=0;                  // Session start minute, inclusive
input int SessionEndHour=0;                      // Session end hour, exclusive; equal start/end = 24h
input int SessionEndMinute=0;                    // Session end minute
input ENUM_SESSION_CLOCK SessionTimeBasis=SERVER_TIME; // Server or GMT clock
input int TesterServerGMTOffsetMinutes=0;        // GMT-session tester only: historical server minus UTC
input group "DISPLAY"
input bool ShowLevels=true;                     // Draw and label reference/SL/TP levels
input bool ShowDashboard=true;                  // Show status in chart comment
input group "LOGGING"
input bool EnableCSVLogging=true;                // Append event snapshots and one final setup row
input string CSVFilePrefix="PHQR_V2_ConfirmedRejection";           // Simple filename prefix, no directory separators

// Plain data only: durable FileWriteStruct checkpoints contain no strings/pointers.
struct Setup
  {
   datetime reference,window_start,window_end,last_m5;
   double h,l,r,q75,q50,q25,sweep_level,atr,reference_open,reference_close,body_ratio,close_location;
   ENUM_SETUP_STATE state;
   ENUM_SKIP_REASON skip;
   ENUM_FILTER_RESULT atr_filter,expansion,spread,news,session;
   bool levels_ready,static_pass,sweep,previous_high_broken,rejection,attempt_consumed;
   bool entry_attempted,entry_placed,entry_filled,order_expired;
   bool be_triggered,be_done,max_hold_exit_requested,signal_no_fill,final_logged,recovered;
   datetime sweep_time,rejection_time,expiry,order_time,fill_time,exit_time,be_time;
   datetime last_be_request,last_close_request,last_cancel_request;
   ulong order_ticket,position_id;
   double rejection_open,rejection_high,rejection_low,rejection_close,rejection_close_location;
   double entry,sl,tp,volume,planned_risk,initial_rr,filled_volume,actual_entry,initial_risk;
   double be_trigger_price,be_price,mfe_r,mae_r;
   double exit_price,pnl,result_r;
   ENUM_EXIT_REASON exit_reason;
  };
struct EntryReservation
  {
   uint symbol_hash;
   datetime reference,deadline;
  };

CTrade g_trade;
Setup g_setups[];
int g_atr=INVALID_HANDLE,g_lock=INVALID_HANDLE,g_current=-1;
long g_generation=0;
string g_scope,g_prefix,g_csv,g_risk_scope;
bool g_test=false,g_history_dirty=true,g_history_ok=false,g_persist_ok=true,g_ready=false;
datetime g_day=0,g_last_dashboard=0,g_last_risk_update=0,g_last_manage=0,g_started=0;
double g_daily_r=0.0;
bool g_daily_ok=false,g_daily_blocked=false;
string g_news_status="NOT_EVALUATED",g_safety_status="";

datetime ServerNow()
  {
   if(g_test) return TimeCurrent();
   datetime t=TimeTradeServer();
   return (t>0 ? t : TimeCurrent());
  }
datetime BrokerDay(const datetime when)
  {
   MqlDateTime d={};
   TimeToStruct(when,d);
   d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
  }
string Stamp(const datetime t) { return (t>0 ? TimeToString(t,TIME_DATE|TIME_SECONDS) : ""); }
string YesNo(const bool b) { return (b ? "yes" : "no"); }
string Number(const double v) { return DoubleToString(v,10); }
bool StatisticsValid(const Setup &s) { return s.skip!=OWNERSHIP_CONFLICT && (!s.entry_filled || s.initial_risk>0); }
uint HashText(const string s)
  {
   uint h=2166136261;
   for(int i=0;i<StringLen(s);i++) h=(h^(uint)StringGetCharacter(s,i))*16777619;
   return h;
  }
string OrderComment(const datetime ref) { return "PHQR2:"+IntegerToString((long)ref); }
datetime CommentReference(const string comment)
  {
   if(StringFind(comment,"PHQR2:")!=0) return 0;
   return (datetime)StringToInteger(StringSubstr(comment,6));
  }
bool IsOwnOrderSelected()
  {
   return OrderGetString(ORDER_SYMBOL)==_Symbol && (ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber;
  }
bool IsOwnHistoryOrder(const ulong ticket)
  {
   return HistoryOrderGetString(ticket,ORDER_SYMBOL)==_Symbol &&
          (ulong)HistoryOrderGetInteger(ticket,ORDER_MAGIC)==MagicNumber &&
          (ENUM_ORDER_TYPE)HistoryOrderGetInteger(ticket,ORDER_TYPE)==ORDER_TYPE_SELL_LIMIT;
  }
bool IsHedging() { return (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING; }
bool ValidTick(MqlTick &tick)
  {
   return SymbolInfoTick(_Symbol,tick) && tick.time>0 && MathIsValidNumber(tick.bid) &&
          MathIsValidNumber(tick.ask) && tick.bid>0 && tick.ask>=tick.bid;
  }
double TickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }
double SnapToTick(const double price,const double tick,const int digits,const int direction=0)
  {
   if(tick<=0 || !MathIsValidNumber(price)) return 0;
   double units=price/tick;
   if(direction>0) units=MathCeil(units-1e-9);
   else if(direction<0) units=MathFloor(units+1e-9);
   else units=MathRound(units);
   return NormalizeDouble(units*tick,digits);
  }
double Snap(const double price,const int direction=0)
  { return SnapToTick(price,TickSize(),(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS),direction); }
double FloorVolume(const double requested,const double step)
  {
   if(step<=0 || requested<=0 || !MathIsValidNumber(requested)) return 0;
   return NormalizeDouble(MathFloor(requested/step+1e-9)*step,8);
  }
bool RangePass(const double range,const double atr,const double low,const double high)
  { return range>0 && atr>0 && range>=low*atr && range<=high*atr; }
bool RejectionBar(const MqlRates &bar,const double sweep,const double previous_high,const double q75,const double q50,const double close_location_max)
  {
   double range=bar.high-bar.low;
   if(range<=0) return false;
   double close_location=(bar.close-bar.low)/range;
   return bar.high>=sweep && bar.high<previous_high && bar.close<q75 && bar.close>q50 &&
          bar.close<bar.open && close_location<=close_location_max;
  }
bool MinuteInSession(const int minute,const int start,const int end)
  {
   if(start==end) return true;
   return (start<end ? minute>=start && minute<end : minute>=start || minute<end);
  }
datetime EntryDeadline(const datetime confirmation,const datetime end,const int bars)
  { return (datetime)MathMin((long)end,(long)confirmation+(long)bars*PeriodSeconds(PERIOD_M5)); }
double BreakEvenTriggerPrice(const Setup &s)
  { return (s.entry_filled && s.sl>s.actual_entry ? s.actual_entry-(s.sl-s.actual_entry) : 0.0); }
bool BreakEvenCloseEligible(const Setup &s,const double close,const datetime closed)
  {
   double trigger=BreakEvenTriggerPrice(s);
   return s.entry_filled && !s.be_triggered && trigger>0 && closed>s.fill_time && close<=trigger;
  }

// Persistence is separate from optional analysis CSV. Alternating complete snapshots
// survive a torn write. An exclusive per-symbol/magic lock prevents duplicate instances.
bool ReadCheckpoint(const string filename,Setup &rows[],long &generation)
  {
   int f=FileOpen(filename,FILE_READ|FILE_BIN);
   if(f==INVALID_HANDLE) return false;
   bool ok=false;
   int version=FileReadInteger(f),count=FileReadInteger(f);
   generation=FileReadLong(f);
   if(version==21000 && count>=0 && count<=100000 &&
      FileSize(f)==(ulong)(24+(long)count*sizeof(Setup)))
     {
      ArrayResize(rows,count);
      ok=true;
      for(int i=0;i<count;i++)
         if(FileReadStruct(f,rows[i])!=sizeof(Setup)) { ok=false; break; }
      if(FileReadLong(f)!=generation) ok=false;
     }
   FileClose(f);
   return ok;
  }
bool SaveState()
  {
   long next=g_generation+1;
   string name=g_scope+((next%2)==0 ? "_state_a.bin" : "_state_b.bin");
   int f=FileOpen(name,FILE_WRITE|FILE_BIN);
   if(f==INVALID_HANDLE)
     {
      g_persist_ok=false;
      PrintFormat("PHQR persistence open failed: %s, error=%d; new orders blocked",name,GetLastError());
      return false;
     }
   int n=ArraySize(g_setups);
   bool ok=(FileWriteInteger(f,21000)==4 && FileWriteInteger(f,n)==4 && FileWriteLong(f,next)==8);
   for(int i=0;i<n && ok;i++) ok=(FileWriteStruct(f,g_setups[i])==sizeof(Setup));
   if(ok) ok=(FileWriteLong(f,next)==8);
   FileFlush(f);
   FileClose(f);
   g_persist_ok=ok;
   if(ok) g_generation=next;
   else Print("PHQR checkpoint write failed; new orders blocked");
   return ok;
  }
void LoadState()
  {
   Setup a[],b[];
   long ga=0,gb=0;
   bool va=ReadCheckpoint(g_scope+"_state_a.bin",a,ga);
   bool vb=ReadCheckpoint(g_scope+"_state_b.bin",b,gb);
   if(va && (!vb || ga>=gb)) { ArrayCopy(g_setups,a); g_generation=ga; }
   else if(vb) { ArrayCopy(g_setups,b); g_generation=gb; }
   else if(FileIsExist(g_scope+"_state_a.bin") || FileIsExist(g_scope+"_state_b.bin"))
      Print("PHQR checkpoints unreadable; reconstructing orders and positions from broker history");
  }
bool WriteCSVLog(const Setup &s,const string event)
  {
   if(!EnableCSVLogging) return true;
   int f=FileOpen(g_csv,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',',CP_UTF8);
   if(f==INVALID_HANDLE) { PrintFormat("PHQR CSV open failed: %s error=%d",g_csv,GetLastError()); return false; }
   if(FileSize(f)==0)
      FileWrite(f,
                "event","event_time_server","magic",
                "reference_timestamp","symbol","reference_open","reference_high","reference_low","reference_close",
                "range","Q75","Q50","Q25","ATR14","range_ATR_ratio","body_ratio","close_location",
                "ATR_filter_pass","expansion_filter_pass","spread_filter_pass","news_filter_pass","session_filter_pass",
                "sweep_detected","sweep_time","previous_high_broken",
                "rejection_detected","rejection_time","rejection_M5_open","rejection_M5_high","rejection_M5_low","rejection_M5_close","rejection_close_location",
                "order_placed","order_time","order_expired","signal_no_fill",
                "actual_entry","initial_SL","TP","initial_RR","lot_size","risk_currency",
                "BE_trigger_price","BE_activated","BE_time",
                "maximum_favorable_excursion","maximum_adverse_excursion",
                "exit_time","exit_price","exit_reason","profit_currency","result_R",
                "setup_state","last_rejection_or_skip_reason","order_ticket","position_id","entry_expiry","account_currency","statistics_valid");
   FileSeek(f,0,SEEK_END);
   double risk_cash=(s.initial_risk>0 ? s.initial_risk : s.planned_risk);
   uint written=FileWrite(f,
                event,Stamp(ServerNow()),IntegerToString((long)MagicNumber),
                Stamp(s.reference),_Symbol,Number(s.reference_open),Number(s.h),Number(s.l),Number(s.reference_close),
                Number(s.r),Number(s.q75),Number(s.q50),Number(s.q25),Number(s.atr),Number(s.atr>0 ? s.r/s.atr : 0.0),Number(s.body_ratio),Number(s.close_location),
                EnumToString(s.atr_filter),EnumToString(s.expansion),EnumToString(s.spread),EnumToString(s.news),EnumToString(s.session),
                YesNo(s.sweep),Stamp(s.sweep_time),YesNo(s.previous_high_broken),
                YesNo(s.rejection),Stamp(s.rejection_time),Number(s.rejection_open),Number(s.rejection_high),Number(s.rejection_low),Number(s.rejection_close),Number(s.rejection_close_location),
                YesNo(s.entry_placed),Stamp(s.order_time),YesNo(s.order_expired),YesNo(s.signal_no_fill),
                Number(s.actual_entry),Number(s.sl),Number(s.tp),Number(s.initial_rr),Number(s.volume),Number(risk_cash),
                Number(s.be_trigger_price),YesNo(s.be_done),Stamp(s.be_time),
                Number(s.mfe_r),Number(s.mae_r),
                Stamp(s.exit_time),Number(s.exit_price),EnumToString(s.exit_reason),Number(s.pnl),(StatisticsValid(s) ? Number(s.result_r) : ""),
                EnumToString(s.state),EnumToString(s.skip),IntegerToString((long)s.order_ticket),IntegerToString((long)s.position_id),Stamp(s.expiry),
                AccountInfoString(ACCOUNT_CURRENCY),YesNo(StatisticsValid(s)));
   FileFlush(f);
   FileClose(f);
   if(written==0) PrintFormat("PHQR CSV write failed, error=%d",GetLastError());
   return written>0;
  }
void Event(Setup &s,const string event)
  {
   PrintFormat("PHQR %s [%s %s] state=%s reason=%s",event,_Symbol,Stamp(s.reference),EnumToString(s.state),EnumToString(s.skip));
   SaveState();
   WriteCSVLog(s,event);
  }
int FindSetup(const datetime ref)
  {
   for(int i=ArraySize(g_setups)-1;i>=0;i--) if(g_setups[i].reference==ref) return i;
   return -1;
  }
bool SelectHistory()
  {
   datetime from=BrokerDay(ServerNow())-86400;
   for(int i=0;i<ArraySize(g_setups);i++)
      if(!g_setups[i].final_logged && g_setups[i].reference<from) from=g_setups[i].reference;
   g_history_ok=HistorySelect(from,ServerNow());
   if(!g_history_ok) PrintFormat("PHQR HistorySelect failed: %d; new entries blocked",GetLastError());
   return g_history_ok;
  }

bool CheckRangeFilter(const Setup &s) { return !UseATRFilter || RangePass(s.r,s.atr,MinATRMultiple,MaxATRMultiple); }
bool CheckExpansionFilter(const Setup &s)
  {
   return !UseExpansionFilter || !(s.reference_close>s.reference_open &&
          s.body_ratio>=ExpansionBodyRatio && s.close_location>=ExpansionCloseLocation);
  }
bool BuildReferenceLevels(Setup &s)
  {
   int shift=iBarShift(_Symbol,PERIOD_H1,s.reference,true);
   if(shift<1) return false;
   MqlRates ref[1];
   if(CopyRates(_Symbol,PERIOD_H1,shift,1,ref)!=1 || ref[0].time!=s.reference) return false;
   double atr[1];
   bool atr_ok=(BarsCalculated(g_atr)>=shift+ATRPeriod+1 && CopyBuffer(g_atr,0,shift,1,atr)==1 &&
                MathIsValidNumber(atr[0]) && atr[0]>0);
   if(UseATRFilter && !atr_ok) return false;
   s.h=ref[0].high; s.l=ref[0].low; s.r=s.h-s.l;
   if(s.r<=0) return false;
   s.reference_open=ref[0].open; s.reference_close=ref[0].close; s.atr=(atr_ok ? atr[0] : 0.0);
   s.q75=s.l+0.75*s.r; s.q50=s.l+0.50*s.r; s.q25=s.l+0.25*s.r;
   s.sweep_level=s.q75+SweepPercent*s.r;
   s.body_ratio=MathAbs(s.reference_close-s.reference_open)/s.r;
   s.close_location=(s.reference_close-s.l)/s.r;
   s.levels_ready=true;
   s.atr_filter=(!UseATRFilter ? FILTER_DISABLED : (CheckRangeFilter(s) ? FILTER_PASS : FILTER_BLOCK));
   s.expansion=(!UseExpansionFilter ? FILTER_DISABLED : (CheckExpansionFilter(s) ? FILTER_PASS : FILTER_BLOCK));
   s.static_pass=CheckRangeFilter(s) && CheckExpansionFilter(s);
   if(!CheckRangeFilter(s)) s.skip=ATR_FILTER_REJECTED;
   else if(!CheckExpansionFilter(s)) s.skip=EXPANSION_FILTER_REJECTED;
   else s.skip=SKIP_NONE;
   s.state=(s.static_pass ? WAITING_FOR_SWEEP : SETUP_FINISHED);
   return true;
  }
int AddSetup(const datetime ref,const datetime window,const bool recovered)
  {
   int found=FindSetup(ref);
   if(found>=0) return found;
   int n=ArraySize(g_setups);
   ArrayResize(g_setups,n+1);
   ZeroMemory(g_setups[n]);
   g_setups[n].reference=ref;
   g_setups[n].window_start=window;
   g_setups[n].window_end=window+PeriodSeconds(PERIOD_H1);
   g_setups[n].last_m5=window-PeriodSeconds(PERIOD_M5);
   g_setups[n].state=REFERENCE_READY;
   g_setups[n].recovered=recovered;
   if(!BuildReferenceLevels(g_setups[n])) g_setups[n].skip=DATA_UNAVAILABLE;
   return n;
  }
datetime InferReference(const datetime order_time)
  {
   int window_shift=iBarShift(_Symbol,PERIOD_H1,order_time,false);
   if(window_shift<0) return 0;
   return iTime(_Symbol,PERIOD_H1,window_shift+1);
  }
datetime WindowFollowingReference(const datetime reference)
  {
   int shift=iBarShift(_Symbol,PERIOD_H1,reference,true);
   if(shift>=1)
     {
      datetime window=iTime(_Symbol,PERIOD_H1,shift-1);
      if(window>0) return window;
     }
   return reference+3600;
  }
void RecoverBrokerObjects()
  {
   if(!SelectHistory()) return;
   // Entry orders in today's/yesterday's history prevent re-entry after a restart,
   // including an already filled, canceled, expired or partially filled order.
   for(int i=0;i<HistoryOrdersTotal();i++)
     {
      ulong t=HistoryOrderGetTicket(i);
      if(t==0 || !IsOwnHistoryOrder(t)) continue;
      datetime ref=CommentReference(HistoryOrderGetString(t,ORDER_COMMENT));
      if(ref==0) ref=InferReference((datetime)HistoryOrderGetInteger(t,ORDER_TIME_SETUP));
      if(ref==0) continue;
      int n=AddSetup(ref,WindowFollowingReference(ref),true);
      if(g_setups[n].order_ticket!=0 && g_setups[n].order_ticket!=t)
         PrintFormat("PHQR WARNING: multiple historical entries for reference %s",Stamp(ref));
      if(g_setups[n].order_ticket==0) g_setups[n].order_ticket=t;
      g_setups[n].attempt_consumed=true; g_setups[n].entry_attempted=true; g_setups[n].entry_placed=true;
     }
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong t=OrderGetTicket(i);
      if(t==0 || !IsOwnOrderSelected()) continue;
      datetime ref=CommentReference(OrderGetString(ORDER_COMMENT));
      if(ref==0) ref=InferReference((datetime)OrderGetInteger(ORDER_TIME_SETUP));
      if(ref==0) { PrintFormat("PHQR cannot identify own order %I64u; entries blocked",t); continue; }
      int n=AddSetup(ref,WindowFollowingReference(ref),true);
      g_setups[n].order_ticket=t;
      g_setups[n].attempt_consumed=true; g_setups[n].entry_attempted=true; g_setups[n].entry_placed=true;
      datetime placed=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(g_setups[n].expiry==0)
        {
         int m=iBarShift(_Symbol,PERIOD_M5,placed,false);
         datetime base=(m>=0 ? iTime(_Symbol,PERIOD_M5,m) : placed);
         g_setups[n].expiry=EntryDeadline(base,g_setups[n].window_end,EntryExpiryM5Bars);
         datetime broker_expiry=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         if(broker_expiry>0) g_setups[n].expiry=(datetime)MathMin((long)g_setups[n].expiry,(long)broker_expiry);
        }
     }
   // An old live position can be older than the normal history scan.
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      datetime ref=CommentReference(PositionGetString(POSITION_COMMENT));
      if(!HistorySelectByPosition(pid)) { g_history_ok=false; continue; }
      ulong entry_order=0;
      for(int j=0;j<HistoryDealsTotal();j++)
        {
         ulong d=HistoryDealGetTicket(j);
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN ||
            (ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=MagicNumber) continue;
         entry_order=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
         datetime from_order=CommentReference(HistoryOrderGetString(entry_order,ORDER_COMMENT));
         if(from_order>0) ref=from_order;
         break;
        }
      if(ref==0) ref=InferReference(opened);
      if(ref==0) { PrintFormat("PHQR cannot reconstruct position %I64u",ticket); continue; }
      int n=AddSetup(ref,WindowFollowingReference(ref),true);
      g_setups[n].position_id=pid;
      if(entry_order>0) g_setups[n].order_ticket=entry_order;
      g_setups[n].attempt_consumed=true; g_setups[n].entry_attempted=true; g_setups[n].entry_placed=true; g_setups[n].entry_filled=true;
     }
   SelectHistory();
   SaveState();
  }
ulong FindPositionTicket(const ulong pid)
  {
   if(pid==0) return 0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t=PositionGetTicket(i);
      if(t>0 && PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)==pid) return t;
     }
   return 0;
  }
bool ExclusivePosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber ||
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_SELL) return false;
   if(IsHedging()) return true;
   ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(!HistorySelectByPosition(pid)) return false;
   bool owned=false,clean=true;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong d=HistoryDealGetTicket(i);
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT)
        {
         if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=MagicNumber || type!=DEAL_TYPE_SELL || e==DEAL_ENTRY_INOUT) clean=false;
         else owned=true;
        }
     }
   SelectHistory();
   return owned && clean && PositionSelectByTicket(ticket);
  }
bool ReservationSeen(const EntryReservation &r)
  {
   for(int i=0;i<OrdersTotal();i++)
     {
      if(OrderGetTicket(i)==0 || (ulong)OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
      if(HashText(OrderGetString(ORDER_SYMBOL))==r.symbol_hash && CommentReference(OrderGetString(ORDER_COMMENT))==r.reference) return true;
     }
   for(int i=0;i<HistoryOrdersTotal();i++)
     {
      ulong t=HistoryOrderGetTicket(i);
      if((ulong)HistoryOrderGetInteger(t,ORDER_MAGIC)!=MagicNumber) continue;
      if(HashText(HistoryOrderGetString(t,ORDER_SYMBOL))==r.symbol_hash &&
         CommentReference(HistoryOrderGetString(t,ORDER_COMMENT))==r.reference) return true;
     }
   return false;
  }
int UnseenEntryReservations()
  {
   string name;
   long search=FileFindFirst(g_risk_scope+"_reserve_*.bin",name);
   if(search==INVALID_HANDLE) return 0;
   int count=0;
   do
     {
      int f=FileOpen(name,FILE_READ|FILE_BIN|FILE_SHARE_READ);
      if(f==INVALID_HANDLE) { count=MaxOpenTrades; break; }
      EntryReservation r={};
      bool read=FileSize(f)==sizeof(EntryReservation) && FileReadStruct(f,r)==sizeof(EntryReservation);
      FileClose(f);
      if(!read) { count=MaxOpenTrades; break; }
      if(r.deadline>ServerNow() && !ReservationSeen(r))
        {
         // The same symbol must not resubmit an uncertain request even when the
         // account-wide cap is larger than one.
         if(r.symbol_hash==HashText(_Symbol)) { count=MaxOpenTrades; break; }
         count++;
        }
     }
   while(FileFindNext(search,name));
   FileFindClose(search);
   return count;
  }
string ReservationFile() { return g_risk_scope+"_reserve_"+IntegerToString((long)HashText(_Symbol))+".bin"; }
bool ReserveEntry(const Setup &s)
  {
   EntryReservation r={};
   r.symbol_hash=HashText(_Symbol); r.reference=s.reference; r.deadline=s.window_end;
   int f=FileOpen(ReservationFile(),FILE_WRITE|FILE_BIN);
   if(f==INVALID_HANDLE) return false;
   bool ok=FileWriteStruct(f,r)==sizeof(EntryReservation);
   FileFlush(f); FileClose(f);
   return ok;
  }
bool EntryExposureSafe()
  {
   bool hedging=IsHedging();
   int reserved=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) reserved++;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(!hedging || (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) return false;
     }
   for(int i=0;i<OrdersTotal();i++)
     {
      if(OrderGetTicket(i)==0) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber) reserved++;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(!hedging || (ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber) return false;
     }
   return reserved+UnseenEntryReservations()<MaxOpenTrades;
  }
bool CheckSpreadFilter(Setup &s,const MqlTick &tick)
  {
   bool pass=s.r>0 && (tick.ask-tick.bid)/s.r<=MaxSpreadRangePercent;
   s.spread=(!UseSpreadFilter ? FILTER_DISABLED : (pass ? FILTER_PASS : FILTER_BLOCK));
   return !UseSpreadFilter || pass;
  }
bool NewsFailure(Setup &s,const string cause)
  {
   bool allow=NewsFilterFailureMode==NEWS_ALLOW_TRADES;
   s.news=(allow ? FILTER_ERROR_ALLOW : FILTER_ERROR_BLOCK);
   g_news_status=EnumToString(s.news)+": "+cause;
   Print("PHQR news filter could not be evaluated: ",cause,"; mode=",EnumToString(NewsFilterFailureMode));
   return allow;
  }
bool CheckNewsFilter(Setup &s)
  {
   if(!UseNewsFilter) { s.news=FILTER_DISABLED; g_news_status="DISABLED"; return true; }
   // MT5 does not expose the native Economic Calendar to Strategy Tester.
   // By default, allow the rest of the PHQR strategy to be backtested instead
   // of silently blocking every otherwise-valid entry. This switch affects
   // tester runs only; live/demo trading still uses the configured news filter
   // and NewsFilterFailureMode exactly as configured.
   if(g_test && TesterAllowTradesWithoutNewsData)
     {
      s.news=FILTER_ERROR_ALLOW;
      g_news_status="TESTER_ALLOW: native Economic Calendar unavailable";
      return true;
     }
   if(g_test) return NewsFailure(s,"native Economic Calendar is unavailable in Strategy Tester");
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return NewsFailure(s,"terminal disconnected");
   MqlCalendarEvent catalog[];
   ResetLastError();
   int count=CalendarEventByCurrency(NewsCurrency,catalog);
   int error=GetLastError();
   if(count<=0 || error!=0) return NewsFailure(s,StringFormat("currency catalog unavailable (%s), error=%d",NewsCurrency,error));
   datetime now=ServerNow();
   MqlCalendarValue values[];
   ResetLastError();
   // Event T blocks [T-before,T+after], so search [now-after,now+before].
   count=CalendarValueHistory(values,now-(long)NewsMinutesAfter*60-1,now+(long)NewsMinutesBefore*60+1,NULL,NewsCurrency);
   error=GetLastError();
   if(count<0 || error!=0) return NewsFailure(s,StringFormat("CalendarValueHistory error=%d",error));
   for(int i=0;i<count;i++)
     {
      MqlCalendarEvent event={};
      ResetLastError();
      if(!CalendarEventById(values[i].event_id,event) || GetLastError()!=0)
         return NewsFailure(s,StringFormat("CalendarEventById error=%d",GetLastError()));
      if(event.importance>=CALENDAR_IMPORTANCE_HIGH && now>=values[i].time-(long)NewsMinutesBefore*60 &&
         now<=values[i].time+(long)NewsMinutesAfter*60)
        {
         s.news=FILTER_BLOCK;
         g_news_status="BLOCK: "+event.name+" @ "+Stamp(values[i].time);
         return false;
        }
     }
   s.news=FILTER_PASS; g_news_status="PASS (last entry check)";
   return true;
  }
bool CheckSessionFilter(Setup &s)
  {
   if(!UseSessionFilter) { s.session=FILTER_DISABLED; return true; }
   datetime now=ServerNow();
   if(SessionTimeBasis==GMT_TIME) now=(g_test ? (datetime)((long)now-(long)TesterServerGMTOffsetMinutes*60) : TimeGMT());
   MqlDateTime d={}; TimeToStruct(now,d);
   bool pass=MinuteInSession(d.hour*60+d.min,SessionStartHour*60+SessionStartMinute,SessionEndHour*60+SessionEndMinute);
   s.session=(pass ? FILTER_PASS : FILTER_BLOCK);
   return pass;
  }
double CalculateStopLoss(const Setup &s,const MqlTick &tick)
  { return Snap(s.h+MathMax(StopBufferPercent*s.r,SpreadMultiplier*(tick.ask-tick.bid)),1); }
double CalculateTakeProfit(const Setup &s) { return Snap(s.q25); }
bool RiskCash(const string symbol,const double volume,const double entry,const double sl,double &cash)
  {
   double profit=0;
   if(volume<=0 || entry<=0 || sl<=entry || !OrderCalcProfit(ORDER_TYPE_SELL,symbol,volume,entry,sl,profit) ||
      !MathIsValidNumber(profit) || profit>=0) return false;
   cash=-profit;
   return cash>0;
  }
bool CalculatePositionSize(Setup &s)
  {
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_value_loss=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double budget=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;
   double distance=s.sl-s.entry;
   if(tick_size<=0 || tick_value<=0 || tick_value_loss<=0 || vmin<=0 || vmax<vmin || step<=0 ||
      budget<=0 || distance<=0)
     { Print("PHQR position sizing: invalid tick value/size, volume specification, equity or risk distance"); return false; }
   double nominal_loss_per_lot=(distance/tick_size)*tick_value_loss;
   if(!MathIsValidNumber(nominal_loss_per_lot) || nominal_loss_per_lot<=0) return false;
   double probe_loss=0;
   if(!RiskCash(_Symbol,vmin,s.entry,s.sl,probe_loss))
     { PrintFormat("PHQR position sizing: OrderCalcProfit validation failed, error=%d",GetLastError()); return false; }
   double loss_per_lot=probe_loss/vmin;
   if(!MathIsValidNumber(loss_per_lot) || loss_per_lot<=0) return false;
   s.volume=FloorVolume(MathMin(vmax,budget/loss_per_lot),step);
   if(s.volume<vmin-1e-9 || s.volume>vmax+1e-9)
     { PrintFormat("PHQR position sizing: %.2f account-currency risk budget cannot support minimum lot %.8f",budget,vmin); return false; }
   // Validate broker-specific calculation mode and currency conversion without assuming a gold contract size.
   if(!RiskCash(_Symbol,s.volume,s.entry,s.sl,s.planned_risk) || s.planned_risk>budget+1e-7)
     { Print("PHQR position sizing: broker-calculated original-stop risk is invalid or exceeds the equity risk budget"); return false; }
   s.initial_risk=s.planned_risk;
   return true;
  }

// A small shared per-position record preserves the entry-time currency conversion
// and full initial-risk denominator across restarts and across symbols of this magic.
string RiskFile(const ulong pid) { return g_risk_scope+"_risk_"+IntegerToString((long)pid)+".bin"; }
void SavePositionRisk(const Setup &s)
  {
   if(s.position_id==0 || s.initial_risk<=0) return;
   int f=FileOpen(RiskFile(s.position_id),FILE_WRITE|FILE_BIN|FILE_SHARE_READ);
   if(f==INVALID_HANDLE) { PrintFormat("PHQR risk ledger write failed: %d",GetLastError()); return; }
   FileWriteDouble(f,s.initial_risk); FileWriteDouble(f,s.filled_volume);
   FileFlush(f); FileClose(f);
  }
bool LoadPositionRisk(const ulong pid,double &risk,double &volume)
  {
   int f=FileOpen(RiskFile(pid),FILE_READ|FILE_BIN|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(f==INVALID_HANDLE) return false;
   bool ok=FileSize(f)==16;
   risk=FileReadDouble(f); volume=FileReadDouble(f);
   FileClose(f);
   return ok && risk>0 && volume>0 && MathIsValidNumber(risk);
  }
datetime LoadDailyGuardDay()
  {
   int f=FileOpen(g_risk_scope+"_daily_guard.bin",FILE_READ|FILE_BIN|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(f==INVALID_HANDLE) return 0;
   datetime day=(FileSize(f)==8 ? (datetime)FileReadLong(f) : BrokerDay(ServerNow()));
   FileClose(f);
   return day;
  }
bool SaveDailyGuardDay(const datetime day)
  {
   int f=FileOpen(g_risk_scope+"_daily_guard.bin",FILE_WRITE|FILE_BIN|FILE_SHARE_READ);
   if(f==INVALID_HANDLE) return false;
   bool ok=FileWriteLong(f,(long)day)==8;
   FileFlush(f); FileClose(f);
   return ok;
  }
void UpdateDailyRisk(const bool force=false)
  {
   datetime now=ServerNow(),day=BrokerDay(now);
   if(!force && day==g_day && now-g_last_risk_update<5) return;
   if(day!=g_day) g_daily_blocked=false;
   g_day=day; g_last_risk_update=now;
   if(LoadDailyGuardDay()==day) g_daily_blocked=true;
   g_daily_r=0; g_daily_ok=false;
   if(!HistorySelect(day,now)) { Print("PHQR daily guard: daily history unavailable"); return; }
   ulong ids[];
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong d=HistoryDealGetTicket(i);
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_OUT && e!=DEAL_ENTRY_OUT_BY && e!=DEAL_ENTRY_INOUT) continue;
      ulong pid=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      if(pid==0) continue;
      bool exists=false;
      for(int j=0;j<ArraySize(ids);j++) if(ids[j]==pid) { exists=true; break; }
      if(!exists) { int n=ArraySize(ids); ArrayResize(ids,n+1); ids[n]=pid; }
     }
   bool good=true;
   for(int p=0;p<ArraySize(ids);p++)
     {
      if(!HistorySelectByPosition(ids[p])) { good=false; continue; }
      bool own=false,mixed=false,reconstructed_complete=true;
      double entry_volume=0,entry_costs=0,day_exit_volume=0,day_cash=0,reconstructed_risk=0;
      for(int j=0;j<HistoryDealsTotal();j++)
        {
         ulong d=HistoryDealGetTicket(j);
         ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
         ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
         double volume=HistoryDealGetDouble(d,DEAL_VOLUME);
         double cash=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+
                     HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
         if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT)
           {
            if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=MagicNumber || type!=DEAL_TYPE_SELL || e==DEAL_ENTRY_INOUT)
               { mixed=true; continue; }
            own=true; entry_volume+=volume; entry_costs+=cash;
            ulong order=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
            double risk=0;
            if(RiskCash(HistoryDealGetString(d,DEAL_SYMBOL),volume,HistoryDealGetDouble(d,DEAL_PRICE),
                        HistoryOrderGetDouble(order,ORDER_SL),risk)) reconstructed_risk+=risk;
            else reconstructed_complete=false;
           }
         else if((datetime)HistoryDealGetInteger(d,DEAL_TIME)>=day)
           { day_exit_volume+=volume; day_cash+=cash; }
        }
      if(!own) continue;
      if(mixed || entry_volume<=0) { good=false; continue; }
      double risk=0,stored_volume=0;
      if(!LoadPositionRisk(ids[p],risk,stored_volume) || MathAbs(stored_volume-entry_volume)>1e-8)
        {
         risk=(reconstructed_complete ? reconstructed_risk : 0);
         PrintFormat("PHQR daily guard: recovered risk for position %I64u from original order SL; current currency conversion used",ids[p]);
        }
      if(risk<=0) { good=false; PrintFormat("PHQR daily guard: cannot reconstruct initial R for position %I64u",ids[p]); continue; }
      day_cash+=entry_costs*MathMin(1.0,day_exit_volume/entry_volume);
      double r=day_cash/risk;
      g_daily_r+=r;
     }
   g_daily_ok=good;
   if(UseDailyLossGuard && g_daily_r<=-MaxDailyLossR && !g_daily_blocked)
     {
      g_daily_blocked=true;
      if(!SaveDailyGuardDay(day)) { g_daily_ok=false; Print("PHQR daily guard latch could not be persisted"); }
      PrintFormat("PHQR daily loss guard latched for %s: net realized daily result %.4f R",Stamp(day),g_daily_r);
     }
   SelectHistory();
  }

bool CheckTradeResult(const bool returned,const string action,const bool pending=false)
  {
   uint code=g_trade.ResultRetcode();
   bool ok=returned && (code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL || (pending && code==TRADE_RETCODE_PLACED));
   if(!ok)
      PrintFormat("PHQR %s failed: method=%s retcode=%u (%s), broker='%s', last_error=%d, order=%I64u deal=%I64u",
                  action,YesNo(returned),code,g_trade.ResultRetcodeDescription(),g_trade.ResultComment(),GetLastError(),
                  g_trade.ResultOrder(),g_trade.ResultDeal());
   return ok;
  }
bool TradingAllowed()
  {
   // An offline Strategy Tester uses its simulated account, not a live connection.
   if(g_test) return MQLInfoInteger(MQL_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
   return TerminalInfoInteger(TERMINAL_CONNECTED) && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
  }
bool SkipEntry(Setup &s,const ENUM_SKIP_REASON why,const string detail="")
  {
   s.skip=why;
   if(s.attempt_consumed && !s.entry_placed && s.state!=SETUP_INVALIDATED) s.state=SETUP_FINISHED;
   PrintFormat("PHQR entry skipped [%s]: %s %s",Stamp(s.reference),EnumToString(why),detail);
   Event(s,"ENTRY_SKIPPED");
   return false;
  }
bool ValidateEntryPrices(const Setup &s,const MqlTick &tick)
  {
   double minimum=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   double eps=TickSize()*1e-7;
   // No widening of strategy stops/targets to satisfy broker constraints.
   // A limit already marketable at placement would chase a missed retest.
   return s.entry>tick.bid && s.entry-tick.bid+eps>=minimum &&
          (freeze<=0 || s.entry-tick.bid>freeze+eps) &&
          s.sl>s.h && s.sl>s.entry && s.tp>0 && s.tp<s.entry &&
          s.sl-s.entry+eps>=minimum && s.entry-s.tp+eps>=minimum;
  }
bool PlaceEntry(Setup &s)
  {
   if(!s.static_pass || !s.attempt_consumed || s.entry_placed || s.entry_filled ||
      s.previous_high_broken || ServerNow()>=s.window_end) return false;
   if(!g_history_ok) return SkipEntry(s,HISTORY_UNAVAILABLE);
   if(!g_persist_ok) return SkipEntry(s,PERSISTENCE_FAILED);
   if(!TradingAllowed()) return SkipEntry(s,TRADE_NOT_ALLOWED);
   ENUM_SYMBOL_TRADE_MODE mode=(ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   long order_mode=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((mode!=SYMBOL_TRADE_MODE_FULL && mode!=SYMBOL_TRADE_MODE_SHORTONLY) ||
      (order_mode&SYMBOL_ORDER_LIMIT)==0 || (order_mode&SYMBOL_ORDER_SL)==0 || (order_mode&SYMBOL_ORDER_TP)==0)
      return SkipEntry(s,SYMBOL_NOT_TRADEABLE,"short limit with attached SL/TP not supported");
   if(!EntryExposureSafe()) return SkipEntry(s,EXISTING_EXPOSURE);
   UpdateDailyRisk(true);
   if(UseDailyLossGuard && (!g_daily_ok || g_daily_blocked || g_daily_r<=-MaxDailyLossR))
      return SkipEntry(s,(!g_daily_ok ? HISTORY_UNAVAILABLE : DAILY_LOSS_LIMIT));
   if(!CheckSessionFilter(s)) return SkipEntry(s,SESSION_FILTER_REJECTED);
   if(!CheckNewsFilter(s)) return SkipEntry(s,NEWS_FILTER_REJECTED,g_news_status);
   MqlTick tick={};
   if(!ValidTick(tick)) return SkipEntry(s,INVALID_QUOTES);
   if(!CheckSpreadFilter(s,tick)) return SkipEntry(s,SPREAD_FILTER_REJECTED);
   s.entry=Snap(s.q75);
   s.sl=CalculateStopLoss(s,tick);
   s.tp=CalculateTakeProfit(s);
   if(!ValidateEntryPrices(s,tick))
      return SkipEntry(s,INVALID_STOPS,"exact rounded PHQR prices do not satisfy stops/freeze level or the Q75 retest already occurred");
   s.initial_rr=(s.entry-s.tp)/(s.sl-s.entry);
   if(s.initial_rr<MinRR) return SkipEntry(s,RR_FILTER_REJECTED);
   if(!CalculatePositionSize(s)) return SkipEntry(s,INVALID_VOLUME);
   double margin=0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL,_Symbol,s.volume,s.entry,margin) || !MathIsValidNumber(margin) ||
      margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return SkipEntry(s,INSUFFICIENT_MARGIN);
   s.expiry=EntryDeadline(s.rejection_time,s.window_end,EntryExpiryM5Bars);
   if(ServerNow()>=s.expiry) return SkipEntry(s,WINDOW_ENDED);
   long expiration_mode=SymbolInfoInteger(_Symbol,SYMBOL_EXPIRATION_MODE);
   ENUM_ORDER_TYPE_TIME tif=ORDER_TIME_GTC;
   datetime expiration=0;
   if((expiration_mode&SYMBOL_EXPIRATION_SPECIFIED)!=0) { tif=ORDER_TIME_SPECIFIED; expiration=s.expiry; }
   else if((expiration_mode&SYMBOL_EXPIRATION_GTC)!=0)
      Print("PHQR broker lacks exact server expiration: using GTC with tick/timer cancellation; terminal must remain running");
   else if((expiration_mode&SYMBOL_EXPIRATION_DAY)!=0)
     { tif=ORDER_TIME_DAY; Print("PHQR broker supports DAY expiration only: local tick/timer deadline also enforced"); }
   else return SkipEntry(s,ORDER_CHECK_FAILED,"no supported pending-order lifetime");

   MqlTradeRequest request={}; MqlTradeCheckResult check={};
   request.action=TRADE_ACTION_PENDING; request.magic=MagicNumber; request.symbol=_Symbol;
   request.volume=s.volume; request.price=s.entry; request.sl=s.sl; request.tp=s.tp;
   request.type=ORDER_TYPE_SELL_LIMIT; request.type_filling=ORDER_FILLING_RETURN;
   request.type_time=tif; request.expiration=expiration; request.comment=OrderComment(s.reference);
   ResetLastError();
   if(!OrderCheck(request,check) || (check.retcode!=TRADE_RETCODE_DONE && check.retcode!=0))
      return SkipEntry(s,ORDER_CHECK_FAILED,StringFormat("retcode=%u comment=%s error=%d",check.retcode,check.comment,GetLastError()));

   int entry_lock=FileOpen(g_risk_scope+"_entry.lock",FILE_READ|FILE_WRITE|FILE_BIN);
   if(entry_lock==INVALID_HANDLE) return SkipEntry(s,EXISTING_EXPOSURE,"another chart is submitting an entry");
   if(!EntryExposureSafe()) { FileClose(entry_lock); return SkipEntry(s,EXISTING_EXPOSURE,"MaxOpenTrades or symbol ownership constraint"); }

   // Persist send intent before the request. attempt_consumed was already latched at the first valid rejection.
   s.entry_attempted=true; s.skip=SKIP_NONE;
   if(!SaveState()) { s.skip=PERSISTENCE_FAILED; FileClose(entry_lock); return false; }
   WriteCSVLog(s,"ENTRY_INTENT");

   // Re-check all time/quote-dependent constraints immediately before submission.
   if(ServerNow()>=s.expiry || !ValidTick(tick) || !ValidateEntryPrices(s,tick) || !EntryExposureSafe())
     { FileClose(entry_lock); return SkipEntry(s,INVALID_STOPS,"quote, exposure or signal window changed during preflight"); }
   if(!CheckSpreadFilter(s,tick)) { FileClose(entry_lock); return SkipEntry(s,SPREAD_FILTER_REJECTED,"spread changed during preflight"); }
   if(!ReserveEntry(s)) { FileClose(entry_lock); return SkipEntry(s,PERSISTENCE_FAILED,"cannot reserve a MaxOpenTrades slot"); }

   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   ResetLastError();
   bool result=g_trade.SellLimit(s.volume,s.entry,_Symbol,s.sl,s.tp,tif,expiration,OrderComment(s.reference));
   bool accepted=CheckTradeResult(result,"SellLimit",true);
   uint code=g_trade.ResultRetcode();
   if(accepted)
     {
      s.order_ticket=g_trade.ResultOrder(); s.entry_placed=true; s.order_time=ServerNow(); s.state=PENDING_ENTRY;
      if(s.order_ticket==0) { s.skip=ORDER_SEND_UNCERTAIN; Print("PHQR accepted request has no order ticket; reconciling history, never resubmitting"); }
      Event(s,"ENTRY_PLACED");
     }
   else
     {
      bool uncertain=(code==0 || code==TRADE_RETCODE_TIMEOUT || code==TRADE_RETCODE_CONNECTION || code==TRADE_RETCODE_ERROR ||
                      g_trade.ResultOrder()!=0 || g_trade.ResultDeal()!=0);
      if(!uncertain) FileDelete(ReservationFile());
      s.skip=(uncertain ? ORDER_SEND_UNCERTAIN : ORDER_SEND_FAILED);
      s.state=SETUP_FINISHED;
      Event(s,"ENTRY_REQUEST_FAILED");
     }
   FileClose(entry_lock);
   g_history_dirty=true;
   return accepted;
  }

ENUM_EXIT_REASON DealExitReason(const Setup &s,const ulong deal)
  {
   ENUM_DEAL_REASON reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(deal,DEAL_REASON);
   if(reason==DEAL_REASON_TP) return TAKE_PROFIT;
   if(reason==DEAL_REASON_SL) return (s.be_done ? BREAK_EVEN_EXIT : STOP_LOSS);
   if(reason==DEAL_REASON_SO) return STOP_OUT;
   if(s.max_hold_exit_requested && reason==DEAL_REASON_EXPERT &&
      (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==MagicNumber) return MAX_HOLD_TIME_EXIT;
   return EXTERNAL_EXIT;
  }
void SyncSetup(Setup &s)
  {
   if(s.final_logged) return;
   if(s.order_ticket==0)
     {
      for(int i=0;i<HistoryOrdersTotal();i++)
        {
         ulong t=HistoryOrderGetTicket(i);
         if(IsOwnHistoryOrder(t) && CommentReference(HistoryOrderGetString(t,ORDER_COMMENT))==s.reference)
           { s.order_ticket=t; s.attempt_consumed=true; s.entry_placed=true; s.entry_attempted=true; break; }
        }
      if(s.order_ticket==0)
         for(int i=0;i<OrdersTotal();i++)
           {
            ulong t=OrderGetTicket(i);
            if(t>0 && IsOwnOrderSelected() && CommentReference(OrderGetString(ORDER_COMMENT))==s.reference)
              { s.order_ticket=t; s.attempt_consumed=true; s.entry_placed=true; s.entry_attempted=true; break; }
           }
     }
   if(s.order_ticket==0) return;
   bool live_order=OrderSelect(s.order_ticket) && IsOwnOrderSelected();
   bool historical=IsOwnHistoryOrder(s.order_ticket);
   if(!live_order && !historical) return;

   s.order_time=(datetime)(live_order ? OrderGetInteger(ORDER_TIME_SETUP) : HistoryOrderGetInteger(s.order_ticket,ORDER_TIME_SETUP));
   if(s.entry==0 || s.sl==0 || s.volume==0)
     {
      s.entry=(live_order ? OrderGetDouble(ORDER_PRICE_OPEN) : HistoryOrderGetDouble(s.order_ticket,ORDER_PRICE_OPEN));
      s.sl=(live_order ? OrderGetDouble(ORDER_SL) : HistoryOrderGetDouble(s.order_ticket,ORDER_SL));
      s.tp=(live_order ? OrderGetDouble(ORDER_TP) : HistoryOrderGetDouble(s.order_ticket,ORDER_TP));
      s.volume=(live_order ? OrderGetDouble(ORDER_VOLUME_INITIAL) : HistoryOrderGetDouble(s.order_ticket,ORDER_VOLUME_INITIAL));
      if(s.sl>s.entry) s.initial_rr=(s.entry-s.tp)/(s.sl-s.entry);
      RiskCash(_Symbol,s.volume,s.entry,s.sl,s.planned_risk);
     }

   double total_volume=0,weighted_entry=0;
   datetime first_fill=0;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong d=HistoryDealGetTicket(i);
      if((ulong)HistoryDealGetInteger(d,DEAL_ORDER)!=s.order_ticket ||
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
      double v=HistoryDealGetDouble(d,DEAL_VOLUME);
      total_volume+=v; weighted_entry+=v*HistoryDealGetDouble(d,DEAL_PRICE);
      s.position_id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      datetime t=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
      if(first_fill==0 || t<first_fill) first_fill=t;
     }
   if(total_volume>0)
     {
      bool changed=!s.entry_filled || MathAbs(s.filled_volume-total_volume)>1e-9 || s.initial_risk<=0;
      s.entry_filled=true; s.filled_volume=total_volume; s.actual_entry=weighted_entry/total_volume; s.fill_time=first_fill;
      s.be_trigger_price=BreakEvenTriggerPrice(s);
      if(changed)
        {
         double stored_risk=0,stored_volume=0;
         if(LoadPositionRisk(s.position_id,stored_risk,stored_volume) && MathAbs(stored_volume-total_volume)<1e-8)
            s.initial_risk=stored_risk;
         else if(!RiskCash(_Symbol,total_volume,s.actual_entry,s.sl,s.initial_risk))
           { s.initial_risk=0; Print("PHQR actual fill risk cannot be valued; daily guard will block if required"); }
         SavePositionRisk(s);
         s.state=POSITION_OPEN;
         Event(s,"ENTRY_FILLED");
        }

      double pnl=0,closed_volume=0,weighted_exit=0;
      ulong last_exit=0;
      datetime exit_time=0;
      for(int i=0;i<HistoryDealsTotal();i++)
        {
         ulong d=HistoryDealGetTicket(i);
         if((ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=s.position_id) continue;
         pnl+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+
              HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);         ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
         if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY || e==DEAL_ENTRY_INOUT)
           {
            double v=HistoryDealGetDouble(d,DEAL_VOLUME);
            closed_volume+=v; weighted_exit+=v*HistoryDealGetDouble(d,DEAL_PRICE);
            datetime t=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
            if(t>=exit_time) { exit_time=t; last_exit=d; }
           }
        }
      s.pnl=pnl;
      s.result_r=(s.initial_risk>0 ? pnl/s.initial_risk : 0);
      if(FindPositionTicket(s.position_id)==0 && closed_volume+1e-8>=total_volume)
        {
         bool changed_exit=s.exit_time!=exit_time || s.exit_reason==EXIT_NONE;
         s.exit_time=exit_time; s.exit_price=(closed_volume>0 ? weighted_exit/closed_volume : 0);
         double original_risk_distance=s.sl-s.actual_entry;
         if(original_risk_distance>0 && s.exit_price>0)
           {
            double exit_favorable=(s.actual_entry-s.exit_price)/original_risk_distance;
            double exit_adverse=(s.exit_price-s.actual_entry)/original_risk_distance;
            if(exit_favorable>s.mfe_r) s.mfe_r=exit_favorable;
            if(exit_adverse>s.mae_r) s.mae_r=exit_adverse;
           }
         s.exit_reason=DealExitReason(s,last_exit);
         if(!live_order) s.state=SETUP_FINISHED;
         if(changed_exit) Event(s,"POSITION_CLOSED");
        }
      else s.state=POSITION_OPEN;
     }
   else if(live_order) s.state=PENDING_ENTRY;
   else
     {
      ENUM_ORDER_STATE os=(ENUM_ORDER_STATE)HistoryOrderGetInteger(s.order_ticket,ORDER_STATE);
      if(os==ORDER_STATE_CANCELED || os==ORDER_STATE_EXPIRED || os==ORDER_STATE_REJECTED)
        {
         bool changed=s.exit_reason==EXIT_NONE;
         s.state=SETUP_FINISHED;
         s.signal_no_fill=(os!=ORDER_STATE_REJECTED);
         s.exit_time=(datetime)HistoryOrderGetInteger(s.order_ticket,ORDER_TIME_DONE);
         s.order_expired=(os==ORDER_STATE_EXPIRED || (s.expiry>0 && s.exit_time>=s.expiry));
         s.exit_reason=(s.order_expired ? ENTRY_EXPIRED : ENTRY_CANCELED);
         if(os==ORDER_STATE_REJECTED) s.exit_reason=ENTRY_REJECTED;
         if(s.signal_no_fill) s.skip=SIGNAL_NO_FILL;
         if(changed) Event(s,(s.signal_no_fill ? "SIGNAL_NO_FILL" : "ENTRY_REJECTED"));
        }
     }
  }
bool DeleteOwnOrder(const ulong ticket,const string reason)
  {
   if(!OrderSelect(ticket)) return true;
   if(!IsOwnOrderSelected()) return false;
   MqlTick tick={};
   double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   if(!ValidTick(tick)) return false;
   if(freeze>0 && MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-tick.bid)<=freeze)
     { PrintFormat("PHQR cannot cancel order %I64u yet: inside broker freeze level (%s); will retry",ticket,reason); return false; }
   if(!TradingAllowed()) return false;
   ResetLastError();
   bool ok=CheckTradeResult(g_trade.OrderDelete(ticket),"OrderDelete "+reason);
   g_history_dirty=true;
   if(ok) PrintFormat("PHQR order %I64u cancellation accepted: %s",ticket,reason);
   return ok;
  }
void ManagePendingOrder(Setup &s)
  {
   if(s.order_ticket==0 || !OrderSelect(s.order_ticket) || !IsOwnOrderSelected()) return;
   if(ServerNow()-s.last_cancel_request<2) return;
   if(ServerNow()>=s.window_end || (s.expiry>0 && ServerNow()>=s.expiry))
     { s.last_cancel_request=ServerNow(); DeleteOwnOrder(s.order_ticket,"signal_no_fill / deadline"); }
   else if(s.entry_filled)
     { s.last_cancel_request=ServerNow(); DeleteOwnOrder(s.order_ticket,"partial fill: cancel unfilled remainder to preserve one position and its BE stop"); }
   else if(!IsHedging())
     {
      // Prevent our pending order from merging into a position opened by somebody else.
      if(PositionSelect(_Symbol)) { s.last_cancel_request=ServerNow(); DeleteOwnOrder(s.order_ticket,"netting ownership conflict"); }
      else
         for(int i=0;i<OrdersTotal();i++)
           {
            ulong other=OrderGetTicket(i);
            if(other>0 && other!=s.order_ticket && OrderGetString(ORDER_SYMBOL)==_Symbol &&
               (ulong)OrderGetInteger(ORDER_MAGIC)!=MagicNumber)
              { s.last_cancel_request=ServerNow(); DeleteOwnOrder(s.order_ticket,"foreign pending order on netting symbol"); break; }
           }
     }
  }
void UpdateExcursions(Setup &s,const MqlTick &tick)
  {
   if(!s.entry_filled || s.exit_time>0 || s.actual_entry<=0 || s.sl<=s.actual_entry) return;
   if(FindPositionTicket(s.position_id)==0) return;
   double original_risk_distance=s.sl-s.actual_entry;
   if(original_risk_distance<=0) return;
   double favorable=(s.actual_entry-tick.ask)/original_risk_distance;
   double adverse=(tick.ask-s.actual_entry)/original_risk_distance;
   if(favorable>s.mfe_r) s.mfe_r=favorable;
   if(adverse>s.mae_r) s.mae_r=adverse;
  }
void CheckBreakEven(Setup &s)
  {
   if(!s.be_triggered || s.be_done) return;
   ulong ticket=FindPositionTicket(s.position_id);
   if(ticket==0 || !ExclusivePosition(ticket)) return;
   // A partially filled pending remainder is canceled before modifying the live position.
   if(s.order_ticket>0 && OrderSelect(s.order_ticket)) return;
   if(!PositionSelectByTicket(ticket)) return;
   double entry=(s.actual_entry>0 ? s.actual_entry : PositionGetDouble(POSITION_PRICE_OPEN));
   double old_sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double target=Snap(entry-BreakEvenOffsetPoints*_Point,-1);
   s.be_price=target;
   if(old_sl>0 && old_sl<=target+TickSize()*1e-7)
     { s.be_done=true; s.be_time=ServerNow(); Event(s,"BE_ALREADY_AT_OR_BETTER"); return; }
   MqlTick tick={};
   if(!ValidTick(tick) || target<=0 || (tp>0 && target<=tp)) return;
   double stops=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   if(target<=tick.ask || target-tick.ask+1e-10<stops ||
      (freeze>0 && (target-tick.ask<=freeze || (old_sl>0 && old_sl-tick.ask<=freeze) || (tp>0 && tick.ask-tp<=freeze)))) return;
   if(!TradingAllowed()) return;
   if(ServerNow()-s.last_be_request<2) return;
   s.last_be_request=ServerNow();
   ResetLastError();
   bool ok=CheckTradeResult(g_trade.PositionModify(ticket,target,tp),"PositionModify BE");
   if(ok && PositionSelectByTicket(ticket) && PositionGetDouble(POSITION_SL)<=target+TickSize()*1e-7 && PositionGetDouble(POSITION_SL)>0)
     { s.be_done=true; s.be_time=ServerNow(); Event(s,"BREAK_EVEN_MOVED"); }
   else if(ok) Print("PHQR BE request accepted but new SL not yet confirmed; will reconcile before retry");
  }
void ManageOpenPosition(Setup &s)
  {
   if(!s.entry_filled || s.exit_time>0) return;
   ulong ticket=FindPositionTicket(s.position_id);
   if(ticket==0) return;
   if(!ExclusivePosition(ticket))
     {
      g_safety_status="OWNERSHIP_CONFLICT: mixed/manual netting exposure; no position modification";
      if(s.skip!=OWNERSHIP_CONFLICT) { s.skip=OWNERSHIP_CONFLICT; Event(s,"OWNERSHIP_CONFLICT"); }
      return;
     }
   CheckBreakEven(s);
   if(!UseMaximumHoldingTime || s.fill_time<=0 || ServerNow()<s.fill_time+(long)MaximumHoldingMinutes*60) return;
   if(!s.max_hold_exit_requested)
     { s.max_hold_exit_requested=true; Event(s,"MAX_HOLD_TIME_EXIT_REQUESTED"); }
   if(!TradingAllowed()) return;
   if(ServerNow()-s.last_close_request<2) return;
   s.last_close_request=ServerNow();
   g_trade.SetTypeFillingBySymbol(_Symbol);
   ResetLastError();
   CheckTradeResult(g_trade.PositionClose(ticket,MaxDeviationPoints),"PositionClose MAX_HOLD_TIME_EXIT");
   g_history_dirty=true;
  }
void ManageDeadlines()
  {
   datetime now=ServerNow();
   for(int i=0;i<ArraySize(g_setups);i++)
     {
      if(g_setups[i].final_logged) continue;
      ManagePendingOrder(g_setups[i]);
      ManageOpenPosition(g_setups[i]);
      if(now>=g_setups[i].window_end && !g_setups[i].entry_placed)
        {
         if(g_setups[i].state!=SETUP_INVALIDATED) g_setups[i].state=SETUP_FINISHED;
         if(g_setups[i].skip==SKIP_NONE) g_setups[i].skip=(g_setups[i].rejection ? WINDOW_ENDED : NO_REJECTION);
        }
     }
  }
void InvalidatePreviousHigh(Setup &s,const double price,const datetime time)
  {
   if(!s.levels_ready || !s.static_pass || s.rejection || s.attempt_consumed || s.previous_high_broken ||
      time<s.window_start || time>=s.window_end) return;
   if(price>=s.h)
     {
      s.previous_high_broken=true;
      s.skip=PREVIOUS_HIGH_BROKEN;
      s.state=SETUP_INVALIDATED;
      Event(s,"PREVIOUS_HIGH_BROKEN");
     }
  }
void DetectSweep(Setup &s,const double price,const datetime time)
  {
   if(!s.levels_ready || !s.static_pass || s.sweep || s.previous_high_broken || s.rejection ||
      time<s.window_start || time>=s.window_end) return;
   if(price>=s.sweep_level && price<s.h)
     {
      s.sweep=true; s.sweep_time=time;
      if(!s.attempt_consumed) s.state=WAITING_FOR_REJECTION;
      Event(s,"SWEEP");
     }
  }
bool DetectM5Rejection(const Setup &s,const MqlRates &bar)
  {
   return bar.time>=s.window_start && bar.time+PeriodSeconds(PERIOD_M5)<=s.window_end &&
          RejectionBar(bar,s.sweep_level,s.h,s.q75,s.q50,RejectionCloseLocationMax);
  }
void ProcessClosedBars(Setup &s,const bool allow_entries)
  {
   if(!s.levels_ready || s.final_logged) return;
   datetime current_m5=iTime(_Symbol,PERIOD_M5,0);
   if(current_m5<=0) return;
   datetime end=(s.entry_filled && s.exit_time==0 ? current_m5-1 : (datetime)MathMin((long)current_m5-1,(long)s.window_end-1));
   datetime begin=(datetime)MathMax((long)s.window_start,(long)s.last_m5+PeriodSeconds(PERIOD_M5));
   if(end<begin) return;
   MqlRates bars[];
   int n=CopyRates(_Symbol,PERIOD_M5,begin,end,bars);
   if(n<0) return;
   for(int i=0;i<n;i++)
     {
      datetime closed=bars[i].time+PeriodSeconds(PERIOD_M5);
      if(bars[i].time<=s.last_m5 || closed>current_m5 || closed>ServerNow()) continue;
      s.last_m5=bars[i].time;
      bool signal_bar=(bars[i].time>=s.window_start && closed<=s.window_end);
      if(signal_bar && !s.rejection && !s.attempt_consumed)
        {
         InvalidatePreviousHigh(s,bars[i].high,bars[i].time);
         if(!s.previous_high_broken)
           {
            bool recovered_sweep=!s.sweep && bars[i].high>=s.sweep_level && bars[i].high<s.h;
            DetectSweep(s,bars[i].high,bars[i].time);
            if(recovered_sweep) WriteCSVLog(s,"SWEEP_FROM_CLOSED_M5_TIME_IS_BAR_OPEN");
            if(s.sweep && s.static_pass && DetectM5Rejection(s,bars[i]))
              {
               double m5range=bars[i].high-bars[i].low;
               s.rejection=true; s.rejection_time=closed; s.attempt_consumed=true;
               s.rejection_open=bars[i].open; s.rejection_high=bars[i].high; s.rejection_low=bars[i].low; s.rejection_close=bars[i].close;
               s.rejection_close_location=(m5range>0 ? (bars[i].close-bars[i].low)/m5range : 0.0);
               Event(s,"M5_REJECTION_CLOSED");
               if(allow_entries && closed>g_started && closed==current_m5 && ServerNow()<s.window_end)
                  PlaceEntry(s);
               else if(!allow_entries) { s.skip=RECOVERY_NO_RETROACTIVE_ENTRY; SaveState(); }
              }
           }
        }
      if(BreakEvenCloseEligible(s,bars[i].close,closed))
        {
         s.be_trigger_price=BreakEvenTriggerPrice(s);
         s.be_triggered=true;
         Event(s,"BREAK_EVEN_CONFIRMED_1R");
        }
     }
   if(n>0) SaveState();
  }
bool DetectNewH1(const bool startup=false)
  {
   datetime window=iTime(_Symbol,PERIOD_H1,0),ref=iTime(_Symbol,PERIOD_H1,1);
   if(window<=0 || ref<=0 || ServerNow()<window || ServerNow()>=window+3600) return false;
   if(g_current>=0 && g_setups[g_current].reference==ref) return false;
   int n=FindSetup(ref);
   bool created=n<0;
   if(created) n=AddSetup(ref,window,startup);
   g_current=n;
   ObjectsDeleteAll(0,g_prefix);
   if(created) Event(g_setups[n],"REFERENCE_CREATED");
   return true;
  }
void FinalizeSetups()
  {
   for(int i=0;i<ArraySize(g_setups);i++)
     {
      if(g_setups[i].final_logged || !g_history_ok) continue;
      bool live_order=g_setups[i].order_ticket>0 && OrderSelect(g_setups[i].order_ticket);
      bool live_position=FindPositionTicket(g_setups[i].position_id)>0;
      if(live_order || live_position) continue;
      bool complete=(g_setups[i].entry_filled && g_setups[i].exit_time>0) ||
                    (g_setups[i].signal_no_fill && g_setups[i].state==SETUP_FINISHED) ||
                    (g_setups[i].exit_reason==ENTRY_REJECTED && g_setups[i].exit_time>0) ||
                    (!g_setups[i].entry_placed && ServerNow()>=g_setups[i].window_end);
      if(!complete) continue;
      g_setups[i].state=SETUP_FINISHED;
      // CSV first, then durable final marker. A crash in between can duplicate a
      // FINAL row; consumers should deduplicate by reference/symbol/magic/run.
      if(WriteCSVLog(g_setups[i],"FINAL"))
        {
         g_setups[i].final_logged=true;
         SaveState();
         PrintFormat("PHQR FINAL [%s] result_R=%.4f exit=%s",Stamp(g_setups[i].reference),g_setups[i].result_r,EnumToString(g_setups[i].exit_reason));
        }
     }
  }
void PruneOldSetups()
  {
   datetime cutoff=BrokerDay(ServerNow())-86400;
   datetime current_ref=(g_current>=0 ? g_setups[g_current].reference : 0);
   bool changed=false;
   for(int i=ArraySize(g_setups)-1;i>=0;i--)
      if(g_setups[i].final_logged && g_setups[i].window_end<cutoff && g_setups[i].reference!=current_ref)
        { ArrayRemove(g_setups,i,1); changed=true; }
   if(changed) { g_current=FindSetup(current_ref); SaveState(); }
  }
void DrawLine(const string name,const double price,const color colour,const datetime label_time)
  {
   if(price<=0) return;
   string line=g_prefix+name,caption=line+"_label";
   if(ObjectFind(0,line)<0) ObjectCreate(0,line,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,line,OBJPROP_PRICE,price);
   ObjectSetInteger(0,line,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,line,OBJPROP_STYLE,STYLE_DOT);
   ObjectSetInteger(0,line,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,line,OBJPROP_TEXT,name+" "+DoubleToString(price,_Digits));
   if(ObjectFind(0,caption)<0) ObjectCreate(0,caption,OBJ_TEXT,0,label_time,price);
   ObjectMove(0,caption,0,label_time,price);
   ObjectSetString(0,caption,OBJPROP_TEXT,name+"  "+DoubleToString(price,_Digits));
   ObjectSetInteger(0,caption,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,caption,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,caption,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,caption,OBJPROP_SELECTABLE,false);
  }
int DisplaySetupIndex()
  {
   // Once positions may outlive their setup H1, show the active trade/pending setup before the newest signal setup.
   for(int i=ArraySize(g_setups)-1;i>=0;i--)
      if(g_setups[i].entry_filled && g_setups[i].exit_time==0 && FindPositionTicket(g_setups[i].position_id)>0) return i;
   for(int i=ArraySize(g_setups)-1;i>=0;i--)
      if(g_setups[i].order_ticket>0 && OrderSelect(g_setups[i].order_ticket) && IsOwnOrderSelected()) return i;
   return g_current;
  }
void DrawLevels()
  {
   if(!ShowLevels) return;
   int idx=DisplaySetupIndex();
   if(idx<0 || !g_setups[idx].levels_ready) return;
   Setup s=g_setups[idx];
   DrawLine("Reference High H",s.h,clrSilver,s.window_start);
   DrawLine("SweepLevel",s.sweep_level,clrGold,s.window_start);
   DrawLine("Q75",s.q75,clrOrange,s.window_start);
   DrawLine("Q50",s.q50,clrDodgerBlue,s.window_start);
   DrawLine("Q25",s.q25,clrLimeGreen,s.window_start);
   DrawLine("Reference Low L",s.l,clrSilver,s.window_start);
   if(s.sl>0) DrawLine("Initial SL",s.sl,clrTomato,s.window_start+300);
   ulong pos=FindPositionTicket(s.position_id);
   if(pos>0 && PositionSelectByTicket(pos))
     {
      double current_sl=PositionGetDouble(POSITION_SL);
      if(current_sl>0 && MathAbs(current_sl-s.sl)>TickSize()*0.1) DrawLine("Current SL",current_sl,clrRed,s.window_start+300);
     }
   if(s.tp>0) DrawLine("TP",s.tp,clrLimeGreen,s.window_start+300);
   if(s.entry_filled && s.actual_entry>0) DrawLine("Actual Entry",s.actual_entry,clrWhite,s.fill_time);
   double be_trigger=(s.be_trigger_price>0 ? s.be_trigger_price : BreakEvenTriggerPrice(s));
   if(be_trigger>0) DrawLine("+1R BE Trigger",be_trigger,clrAqua,s.fill_time);
  }
void UpdateDashboard()
  {
   if(!ShowDashboard) return;
   int idx=DisplaySetupIndex();
   if(idx<0) { Comment("PHQR V2 - Confirmed Quartile Rejection | ",_Symbol,"\nWAITING_FOR_NEW_H1 / waiting for completed H1 and ATR history"); return; }
   Setup s=g_setups[idx];
   MqlTick tick={};
   bool quote=ValidTick(tick);
   double current_r=0,current_sl=s.sl;
   ulong pos=FindPositionTicket(s.position_id);
   bool position_open=(pos>0 && PositionSelectByTicket(pos));
   if(position_open)
     {
      current_sl=PositionGetDouble(POSITION_SL);
      if(quote && s.sl>s.actual_entry) current_r=(s.actual_entry-tick.ask)/(s.sl-s.actual_entry);
     }
   bool pending=s.order_ticket>0 && OrderSelect(s.order_ticket) && IsOwnOrderSelected();
   string spread_status="INVALID_QUOTES";
   if(!UseSpreadFilter) spread_status="DISABLED";
   else if(quote && s.r>0) spread_status=StringFormat("%s (%.4f of range)",((tick.ask-tick.bid)/s.r<=MaxSpreadRangePercent ? "PASS" : "BLOCK"),(tick.ask-tick.bid)/s.r);
   string session_status=EnumToString(s.session);
   if(!UseSessionFilter) session_status="FILTER_DISABLED";
   string text="PHQR V2 - Confirmed Quartile Rejection | "+_Symbol+"\n";
   text+=StringFormat("Risk %.2f%% equity | Max own open trades %d | Max hold %s\n",RiskPercent,MaxOpenTrades,(UseMaximumHoldingTime ? IntegerToString(MaximumHoldingMinutes)+" min" : "OFF"));
   text+="Reference candle: "+Stamp(s.reference)+" | Setup window: "+Stamp(s.window_start)+" -> "+Stamp(s.window_end)+"\n";
   text+=StringFormat("H %.*f | Sweep %.*f | Q75 %.*f | Q50 %.*f | Q25 %.*f | L %.*f\n",_Digits,s.h,_Digits,s.sweep_level,_Digits,s.q75,_Digits,s.q50,_Digits,s.q25,_Digits,s.l);
   text+=StringFormat("Range %.*f | ATR%d %.*f | Range/ATR %.4f | ATR filter %s\n",_Digits,s.r,ATRPeriod,_Digits,s.atr,(s.atr>0 ? s.r/s.atr : 0.0),EnumToString(s.atr_filter));
   text+="Expansion filter: "+EnumToString(s.expansion)+" | Sweep: "+YesNo(s.sweep)+" @ "+Stamp(s.sweep_time)+"\n";
   text+="Previous H1 high broken before rejection: "+YesNo(s.previous_high_broken)+" | Rejection: "+YesNo(s.rejection)+" @ "+Stamp(s.rejection_time)+"\n";
   text+="Setup state: "+EnumToString(s.state)+" | Pending: "+(pending ? "OPEN #"+IntegerToString((long)s.order_ticket)+" until "+Stamp(s.expiry) : "none")+"\n";
   text+="Position: "+(position_open ? "OPEN #"+IntegerToString((long)pos) : "none")+" | BE confirmed: "+YesNo(s.be_triggered)+" | BE moved: "+YesNo(s.be_done)+"\n";
   text+=StringFormat("Actual entry %.*f | Initial SL %.*f | Current SL %.*f | TP %.*f | +1R %.*f | Current R %.3f\n",
                      _Digits,s.actual_entry,_Digits,s.sl,_Digits,current_sl,_Digits,s.tp,_Digits,(s.be_trigger_price>0 ? s.be_trigger_price : BreakEvenTriggerPrice(s)),current_r);
   text+=StringFormat("Daily R %.3f | Guard %.3f R | Latched %s | History %s | MFE %.3f R | MAE %.3f R\n",
                      g_daily_r,MaxDailyLossR,YesNo(g_daily_blocked),YesNo(g_daily_ok),s.mfe_r,s.mae_r);
   text+="Spread: "+spread_status+" | News: "+g_news_status+" | Session: "+session_status+"\n";
   text+="Last rejection/skip reason: "+EnumToString(s.skip)+"\n";
   if(g_safety_status!="") text+=g_safety_status+"\n";
   if(!g_persist_ok) text+="PERSISTENCE ERROR: new entries blocked\n";
   Comment(text);
  }
bool ValidateInputs()
  {
   if(EnableLongStrategy) { Print("PHQR EnableLongStrategy=true is unsupported: this version is intentionally short-only"); return false; }
   if(MagicNumber==0 || MagicNumber>LONG_MAX || MaxOpenTrades<1 || RiskPercent<=0 || RiskPercent>100 || ATRPeriod<1 || ATRPeriod>10000 ||
      MinATRMultiple<0 || MaxATRMultiple<MinATRMultiple || MaxATRMultiple<=0 ||
      ExpansionBodyRatio<0 || ExpansionBodyRatio>1 || ExpansionCloseLocation<0 || ExpansionCloseLocation>1 ||
      SweepPercent<0 || RejectionCloseLocationMax<0 || RejectionCloseLocationMax>1 ||
      EntryExpiryM5Bars<1 || EntryExpiryM5Bars>100000 || StopBufferPercent<0 || SpreadMultiplier<0 || MinRR<=0 ||
      BreakEvenOffsetPoints<0 || MaximumHoldingMinutes<1 || MaxDailyLossR<=0 || MaxSpreadRangePercent<0 ||
      NewsMinutesBefore<0 || NewsMinutesAfter<0 || NewsMinutesBefore>10080 || NewsMinutesAfter>10080 ||
      (UseNewsFilter && StringLen(NewsCurrency)==0) || SessionStartHour<0 || SessionStartHour>23 ||
      SessionEndHour<0 || SessionEndHour>23 || SessionStartMinute<0 || SessionStartMinute>59 ||
      SessionEndMinute<0 || SessionEndMinute>59 || TesterServerGMTOffsetMinutes < -1440 || TesterServerGMTOffsetMinutes>1440 ||
      StringLen(CSVFilePrefix)==0 || StringFind(CSVFilePrefix,"\\")>=0 || StringFind(CSVFilePrefix,"/")>=0 || StringFind(CSVFilePrefix,":")>=0)
     { Print("PHQR invalid inputs: check risk, ATR/signal thresholds, holding/session/news fields, magic and filename prefix"); return false; }
   return true;
  }
void Pump(const bool from_tick)
  {
   if(!g_ready) return;
   datetime now=ServerNow();
   if(g_started<=0) g_started=now;
   static datetime last_sync=0;
   if(g_history_dirty || now-last_sync>=2)
     {
      if(SelectHistory())
        {
         for(int i=0;i<ArraySize(g_setups);i++) SyncSetup(g_setups[i]);
         g_history_dirty=false;
        }
      last_sync=now;
     }
   UpdateDailyRisk();
   if(now!=g_last_manage || from_tick)
     {
      ManageDeadlines();
      g_last_manage=now;
     }

   if(from_tick)
     {
      // Finish observations from the old setup before advancing the reference hour.
      if(g_current>=0 && now>=g_setups[g_current].window_end) ProcessClosedBars(g_setups[g_current],false);
      bool new_hour=DetectNewH1();
      if(g_current>=0 && !g_setups[g_current].levels_ready && BuildReferenceLevels(g_setups[g_current]))
         Event(g_setups[g_current],"REFERENCE_READY");

      // Process closed M5 bars for the current signal setup and any older still-open position.
      for(int i=0;i<ArraySize(g_setups);i++)
        {
         bool needs_bars=(i==g_current) || (g_setups[i].entry_filled && g_setups[i].exit_time==0);
         if(needs_bars) ProcessClosedBars(g_setups[i],i==g_current);
        }

      MqlTick tick={};
      if(ValidTick(tick))
        {
         if(g_current>=0)
           {
            double price=((ENUM_SYMBOL_CHART_MODE)SymbolInfoInteger(_Symbol,SYMBOL_CHART_MODE)==SYMBOL_CHART_MODE_LAST ? tick.last : tick.bid);
            if(price>0)
              {
               InvalidatePreviousHigh(g_setups[g_current],price,tick.time);
               DetectSweep(g_setups[g_current],price,tick.time);
              }
           }
         for(int i=0;i<ArraySize(g_setups);i++) UpdateExcursions(g_setups[i],tick);
        }
      // A newly closed M5 bar may just have confirmed +1R, so apply BE without waiting for the timer.
      for(int i=0;i<ArraySize(g_setups);i++) ManageOpenPosition(g_setups[i]);
      if(new_hour) PruneOldSetups();
     }

   if(g_history_dirty && SelectHistory())
     {
      for(int i=0;i<ArraySize(g_setups);i++) SyncSetup(g_setups[i]);
      g_history_dirty=false;
      UpdateDailyRisk(true);
     }
   FinalizeSetups();
   if(now!=g_last_dashboard) { DrawLevels(); UpdateDashboard(); g_last_dashboard=now; }
  }

void PrintTesterAuditSummary()
  {
   if(!g_test) return;
   int total=ArraySize(g_setups),levels=0,static_pass=0,sweeps=0,rejections=0,placed=0,filled=0,no_fill=0;
   int wins=0,losses=0,flat=0,valid_r=0,rr_count=0,rr_below=0;
   double rr_sum=0.0,r_sum=0.0,win_r_sum=0.0,loss_r_sum=0.0;
   int win_r_count=0,loss_r_count=0;
   int exit_counts[],skip_counts[];
   ArrayResize(exit_counts,(int)ENTRY_REJECTED+1); ArrayInitialize(exit_counts,0);
   ArrayResize(skip_counts,(int)DATA_UNAVAILABLE+1); ArrayInitialize(skip_counts,0);
   for(int i=0;i<total;i++)
     {
      if(g_setups[i].levels_ready) levels++;
      if(g_setups[i].static_pass) static_pass++;
      if(g_setups[i].sweep) sweeps++;
      if(g_setups[i].rejection) rejections++;
      if(g_setups[i].entry_placed) placed++;
      if(g_setups[i].entry_filled) filled++;
      if(g_setups[i].signal_no_fill) no_fill++;
      int sk=(int)g_setups[i].skip;
      if(sk>=0 && sk<ArraySize(skip_counts)) skip_counts[sk]++;
      int ex=(int)g_setups[i].exit_reason;
      if(ex>=0 && ex<ArraySize(exit_counts)) exit_counts[ex]++;
      if(g_setups[i].entry_filled)
        {
         if(g_setups[i].initial_rr>0 && MathIsValidNumber(g_setups[i].initial_rr))
           {
            rr_sum+=g_setups[i].initial_rr; rr_count++;
            if(g_setups[i].initial_rr+1e-9<MinRR) rr_below++;
           }
         if(g_setups[i].pnl>1e-8) wins++;
         else if(g_setups[i].pnl<-1e-8) losses++;
         else flat++;
         if(g_setups[i].initial_risk>0 && MathIsValidNumber(g_setups[i].result_r))
           {
            r_sum+=g_setups[i].result_r; valid_r++;
            if(g_setups[i].result_r>0) { win_r_sum+=g_setups[i].result_r; win_r_count++; }
            else if(g_setups[i].result_r<0) { loss_r_sum+=g_setups[i].result_r; loss_r_count++; }
           }
        }
     }
   Print("PHQR AUDIT ===== tester summary =====");
   PrintFormat("PHQR AUDIT setups=%d levels_ready=%d static_pass=%d sweeps=%d rejections=%d orders_placed=%d fills=%d no_fill=%d",
               total,levels,static_pass,sweeps,rejections,placed,filled,no_fill);
   PrintFormat("PHQR AUDIT filled P/L: wins=%d losses=%d flat=%d",wins,losses,flat);
   PrintFormat("PHQR AUDIT initial_RR: count=%d avg=%.4f below_MinRR=%d MinRR=%.4f",
               rr_count,(rr_count>0 ? rr_sum/rr_count : 0.0),rr_below,MinRR);
   PrintFormat("PHQR AUDIT realized_R: count=%d avg=%.4f avg_win=%.4f avg_loss=%.4f",
               valid_r,(valid_r>0 ? r_sum/valid_r : 0.0),
               (win_r_count>0 ? win_r_sum/win_r_count : 0.0),
               (loss_r_count>0 ? loss_r_sum/loss_r_count : 0.0));
   for(int i=0;i<ArraySize(exit_counts);i++)
      if(exit_counts[i]>0) PrintFormat("PHQR AUDIT exit_reason %s = %d",EnumToString((ENUM_EXIT_REASON)i),exit_counts[i]);
   for(int i=0;i<ArraySize(skip_counts);i++)
      if(skip_counts[i]>0) PrintFormat("PHQR AUDIT final_skip %s = %d",EnumToString((ENUM_SKIP_REASON)i),skip_counts[i]);
   Print("PHQR AUDIT ============================");
  }

#ifndef PHQR_TEST
int OnInit()
  {
   if(!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;
   g_test=(bool)MQLInfoInteger(MQL_TESTER);
   g_started=ServerNow();
   if(!UseNewsFilter) g_news_status="DISABLED";
   string identity=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"_"+IntegerToString((long)HashText(AccountInfoString(ACCOUNT_SERVER)))+"_"+IntegerToString((long)MagicNumber);
   string run=(g_test ? "_test_"+IntegerToString((long)GetMicrosecondCount()) : "");
   g_risk_scope="PHQR2_"+identity+run;
   g_scope=g_risk_scope+"_"+IntegerToString((long)HashText(_Symbol));
   g_prefix="PHQR2_"+IntegerToString((long)MagicNumber)+"_";
   g_csv=CSVFilePrefix+"_"+identity+"_"+IntegerToString((long)HashText(_Symbol))+run+".csv";
   ResetLastError();
   g_lock=FileOpen(g_scope+".lock",FILE_READ|FILE_WRITE|FILE_BIN);
   if(g_lock==INVALID_HANDLE)
     { PrintFormat("PHQR instance lock failed: another EA uses this account/symbol/magic, or file access failed (%d)",GetLastError()); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol,true)) { Print("PHQR cannot select chart symbol"); return INIT_FAILED; }
   g_atr=iATR(_Symbol,PERIOD_H1,ATRPeriod);
   if(g_atr==INVALID_HANDLE) { PrintFormat("PHQR iATR handle creation failed: %d",GetLastError()); return INIT_FAILED; }
   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(MaxDeviationPoints);
   g_trade.SetAsyncMode(false);
   g_trade.SetMarginMode();
   g_trade.SetTypeFillingBySymbol(_Symbol);
   if(!g_test) LoadState();
   RecoverBrokerObjects();
   DetectNewH1(true);
   if(SelectHistory()) for(int i=0;i<ArraySize(g_setups);i++) SyncSetup(g_setups[i]);
   // Reconstruct closed-bar observations and BE triggers without backdated entries.
   for(int i=0;i<ArraySize(g_setups);i++) ProcessClosedBars(g_setups[i],false);
   UpdateDailyRisk(true);
   g_ready=true;
   if(!EventSetTimer(1)) { PrintFormat("PHQR timer initialization failed: %d",GetLastError()); return INIT_FAILED; }
   ManageDeadlines();
   DrawLevels(); UpdateDashboard();
   PrintFormat("PHQR V2 - Confirmed Quartile Rejection initialized on %s; short only; magic=%I64u; CSV=%s",_Symbol,MagicNumber,g_csv);
   if(g_test && UseNewsFilter && TesterAllowTradesWithoutNewsData)
      Print("PHQR Strategy Tester: native news unavailable; TesterAllowTradesWithoutNewsData=true, so otherwise-valid PHQR entries may trade. Live/demo news filtering is unchanged.");
   else if(g_test && UseNewsFilter)
      Print("PHQR Strategy Tester: native news unavailable; tester bypass disabled, configured fail mode=",EnumToString(NewsFilterFailureMode));
   if(UseSessionFilter && SessionTimeBasis==GMT_TIME && g_test)
      PrintFormat("PHQR GMT session tester offset: server minus GMT = %d minutes (set historical offset, split DST periods if needed)",TesterServerGMTOffsetMinutes);
   return INIT_SUCCEEDED;
  }
void OnTick() { Pump(true); }
void OnTimer() { Pump(false); }
void OnTradeTransaction(const MqlTradeTransaction &transaction,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   // Notifications are deliberately lightweight; a request may generate several,
   // and their delivery order is not guaranteed. Reconcile broker truth in Pump.
   g_history_dirty=true;
  }
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_ready)
     {
      if(SelectHistory()) for(int i=0;i<ArraySize(g_setups);i++) SyncSetup(g_setups[i]);
      PrintTesterAuditSummary();
      SaveState();
      for(int i=0;i<ArraySize(g_setups);i++)
         if(!g_setups[i].final_logged) WriteCSVLog(g_setups[i],(g_test ? "TEST_END_OPEN_OR_INCOMPLETE" : "EA_DEINITIALIZED"));
     }
   if(g_atr!=INVALID_HANDLE) { IndicatorRelease(g_atr); g_atr=INVALID_HANDLE; }
   if(g_lock!=INVALID_HANDLE) { FileClose(g_lock); g_lock=INVALID_HANDLE; }
   if(g_prefix!="") ObjectsDeleteAll(0,g_prefix);
   if(ShowDashboard && g_ready) Comment("");
   g_ready=false;
  }
#endif