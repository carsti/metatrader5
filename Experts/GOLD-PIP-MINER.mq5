//+------------------------------------------------------------------+
//|                                 GOLD-PIP MINER EA V6 MQ5.mq5     |
//|                                         |
//+------------------------------------------------------------------+
#property strict
#property version     "6.0"


#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Developer Comment Constant
const string EA_COMMENT = "GOLD-PIP MINER EA V6";

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
enum ENUM_N1_MODE
{
   N0 = 0,   // All News Importance Levels
   N1 = 1,   // Medium and High-Impact News
   N2 = 2    // High-Impact News Only
};


input group "=== A. INITIAL ORDER SETTINGS ==="
input double   D1 = 1.00;                      // Pending Order Distance from Market (Price)
input double   V1 = 0.01;                      // Initial Lot Size

input group "=== B. GRID AND BASKET SETTINGS ==="
input int      N  = 10;                        // Maximum Positions per Basket
input double   S1 = 13.0;                      // Initial Grid Spacing (Price)
input double   S2 = 2.60;                      // Later Grid Spacing (Price)
input double   T1 = 40.00;                     // Basket Profit Target per Lot (Account Currency)
input double   E1 = 1.68;                      // Grid Lot Multiplier
input double   R1 = 0.0;                       // Initial Lot Scaling Factor (0=Off, 1=100%, 0.2=20%)
input double   P1 = 0.50;                      // Maximum Allowed Spread (Price)
input int      P2 = 2;                         // Grid Additions Using Initial Spacing
input double   H1 = 0.0;                       // Reserved Parameter (Currently Unused)

input group "=== C. TRADE IDENTIFICATION ==="
input ulong    M1 = 123456;                    // Buy Trades Magic Number
input ulong    M2 = 123457;                    // Sell Trades Magic Number

input group "=== D. TRADING SESSION FILTER ==="
input bool     F1 = true;                      // Enable Trading Session Filter
input int      T2 = 1;                         // Session Start Hour (Broker Time)
input int      T3 = 15;                        // Session Start Minute (Broker Time)
input int      T4 = 22;                        // Session End Hour (Broker Time)
input int      T5 = 0;                         // Session End Minute (Broker Time)
input bool     F2 = false;                     // Cancel Pending Orders When New Entries Are Blocked

input group "=== E. DAILY PROFIT LIMIT ==="
input bool     F3 = false;                     // Stop New Cycles at Daily Profit Target
input double   DT1 = 0.0;                      // Daily Realized Profit Target (Account Currency)

input group "=== F. USD ECONOMIC NEWS FILTER ==="
input bool     F4 = false;                     // Enable USD Economic News Filter
input ENUM_N1_MODE InpNewsMode = N2;           // News Importance Level
input int      T6 = 30;                        // Pause Before News (Minutes)
input int      T7 = 30;                        // Resume After News (Minutes)

input bool     ShowDashboard      = true;      // Show the Sovereign dashboard
input bool     ShowVertexIQ       = true;      // Show the Vertex-IQ heat panel
input int      VertexRows         = 16;        // Heat cells per timeframe band
input int      VertexCols         = 6;         // Number of timeframe bands (stacked)
input bool     ShowAdvancedPanels = true;      // Show sparkline / ladder / thermometer / ticker / spinner
input bool     ShowSessionClock   = true;      // Show live broker session clock panel
input bool     ShowMarketPulse    = true;      // Show recent-candle market pulse strip
input bool     ShowVolatilityGauge= true;      // Show ATR-based volatility gauge
input bool     ShowConfidenceArc  = true;      // Show the multi-factor confidence arc
input bool     ShowDataRain       = true;      // Show the ambient data-rain accent column
input int      AnimationSpeed     = 1;         // Animation speed multiplier (1=normal, 2=fast, 3=very fast)


input group "=== G. BASKET STOP-LOSS ==="
input double   BasketMaxLoss = 200.0;              // Max Basket Loss, Account Currency (0=disabled)

input group "=== H. MAX DRAWDOWN PROTECTION ==="
input bool               InpEnableMaxDDProtection = false;      // Enable Max Drawdown Protection (restart to activate)
input double             InpMaxDrawdownPercent    = 30.0;       // Max Drawdown Threshold (%)
input ENUM_AFTER_MAX_DD  InpAfterMaxDD            = DD_STOP_TRADING; // Action After Max DD Triggered

input group "=== I. MARGIN PROTECTION ==="
input double   InpMinMarginLevel = 300.0;          // Minimum Margin Level for new Grid Trades (%)

input group "=== J. CHART DISPLAY SETTINGS ==="
input bool     ShowTradeArrows     = false;    // Show MT5 Buy/Sell/TP/SL Chart Markers
input bool     AutoCleanArrows     = true;     // Periodically Remove Chart Markers
input int      ArrowCleanupSeconds = 1;        // Chart Marker Cleanup Interval (Seconds)
// NOTE: this only toggles/removes the CHART-side marker objects. It has no effect whatsoever on the
// broker's server-side trade history, the terminal's History tab, or the account statement - those
// records are independent of chart objects and cannot be altered by an EA.

//--- Fixed internal settings: intentionally hidden from the user Inputs tab
//    (matches the STEVE STRADDLE reference file - same values GoldTrap_Replica
//    already used, simply no longer exposed as editable inputs).
const ulong    InpSlippage               = 30;
const double   InpMaxLot                 = 1000.00;
const bool     InpUpdateBrokerTP         = true;
const int      InpMinimumDelayBetweenOrders = 1;
const bool     InpEnableLogs             = true;
const int      InpNewsLookAheadDays      = 14;
const bool     InpCancelPendingsForNews  = true;
const int      InpNewsRefreshSeconds     = 30;

enum ENUM_AFTER_MAX_DD
{
   DD_CONTINUE_TRADING = 0,   // Continue Trading
   DD_STOP_TRADING     = 1    // Stop Trading
};

// MaxDD settings are now in input group H above (not const) so users can enable them

//+------------------------------------------------------------------+
//| ENUMERATIONS & STATE MACHINE                                     |
//+------------------------------------------------------------------+
enum ENUM_EA_STATE
{
   STATE_INIT,
   STATE_WAITING_FOR_TRIGGER,
   STATE_BUY_BASKET_ACTIVE,
   STATE_SELL_BASKET_ACTIVE,
   STATE_CLOSING_BASKET,
   STATE_RESETTING_CYCLE
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
COrderInfo     m_order;

ENUM_EA_STATE  g_state = STATE_INIT;
datetime       g_last_order_time = 0;
datetime       g_last_arrow_cleanup = 0;
datetime       g_last_tp_update_time[2] = {0, 0};
datetime       g_last_tp_skip_log_time[2] = {0, 0};

bool           g_max_dd_emergency_active   = false;
bool           g_trading_stopped_by_max_dd = false;

bool           g_news_blocked       = false;
bool           g_calendar_available = true;
datetime       g_last_news_scan     = 0;
datetime       g_next_news_time     = 0;
string         g_next_news_name     = "No scheduled high-impact USD news";
string         g_active_news_name   = "";

bool IsOurMagic(const long magic)
{
   return ((ulong)magic == M1 || (ulong)magic == M2);
}

void SetTradeMagic(const ulong magic)
{
   m_trade.SetExpertMagicNumber(magic);
}

//+------------------------------------------------------------------+
//| RECONSTRUCT STATE ON STARTUP / REATTACH / TICK                   |
//+------------------------------------------------------------------+
void ReconstructState()
{
   int buy_pos_count  = 0;
   int sell_pos_count = 0;
   int buy_stop_count = 0;
   int sell_stop_count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()))
         {
            if(m_position.PositionType() == POSITION_TYPE_BUY)
               buy_pos_count++;
            else if(m_position.PositionType() == POSITION_TYPE_SELL)
               sell_pos_count++;
         }
      }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i))
      {
         if(m_order.Symbol() == _Symbol && IsOurMagic(m_order.Magic()))
         {
            if(m_order.OrderType() == ORDER_TYPE_BUY_STOP)
               buy_stop_count++;
            else if(m_order.OrderType() == ORDER_TYPE_SELL_STOP)
               sell_stop_count++;
         }
      }
   }

   if(buy_pos_count > 0 && sell_pos_count == 0)
   {
      if(sell_stop_count > 0)
      {
         LogMessage("BUY Basket triggered. Deleting opposite Sell Stop order.");
         CancelPendingOrders(ORDER_TYPE_SELL_STOP);
      }
      if(g_state != STATE_CLOSING_BASKET)
         g_state = STATE_BUY_BASKET_ACTIVE;

      UpdateBrokerBasketTP(POSITION_TYPE_BUY);
   }
   else if(sell_pos_count > 0 && buy_pos_count == 0)
   {
      if(buy_stop_count > 0)
      {
         LogMessage("SELL Basket triggered. Deleting opposite Buy Stop order.");
         CancelPendingOrders(ORDER_TYPE_BUY_STOP);
      }
      if(g_state != STATE_CLOSING_BASKET)
         g_state = STATE_SELL_BASKET_ACTIVE;

      UpdateBrokerBasketTP(POSITION_TYPE_SELL);
   }
   else if(buy_pos_count == 0 && sell_pos_count == 0)
   {
      if(buy_stop_count > 0 || sell_stop_count > 0)
      {
         g_state = STATE_WAITING_FOR_TRIGGER;
      }
      else
      {
         g_state = STATE_RESETTING_CYCLE;
      }
   }
   else if(buy_pos_count > 0 && sell_pos_count > 0)
   {
      Print("[EA WARNING] Hedging overlap detected (both BUY and SELL positions exist). Grid entries paused for safety.");
   }
}

void ProcessWaitingForTriggerState()
{
   int buy_stop_count = 0;
   int sell_stop_count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i))
      {
         if(m_order.Symbol() == _Symbol && IsOurMagic(m_order.Magic()))
         {
            if(m_order.OrderType() == ORDER_TYPE_BUY_STOP) buy_stop_count++;
            if(m_order.OrderType() == ORDER_TYPE_SELL_STOP) sell_stop_count++;
         }
      }
   }

   bool news_blocked = IsNewsWindowBlocked();
   bool entry_allowed = CanStartNewCycle();
   if(!entry_allowed)
   {
      bool must_cancel_for_news = (news_blocked && InpCancelPendingsForNews);
      if((must_cancel_for_news || F2) && GetPositionCount() == 0 && (buy_stop_count > 0 || sell_stop_count > 0))
         CancelAllPendingOrders();
      return;
   }

   if(buy_stop_count == 1 && sell_stop_count == 1)
      return;

   if(GetPositionCount() == 0)
   {
      PlaceInitialPendingOrders();
   }
}

void PlaceInitialPendingOrders()
{
   if(!CanStartNewCycle() || IsSpreadExceeded()) return;

   CancelAllPendingOrders();

   // A pending order can temporarily be inside the broker freeze zone and
   // therefore cannot be deleted.  Never stack a second straddle on top of
   // an order that the server has not actually removed.
   if(GetPendingOrderCount() > 0)
   {
      LogMessage("New-cycle placement postponed: an old pending order is still present.");
      g_state = STATE_WAITING_FOR_TRIGGER;
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ref_price = (ask + bid) / 2.0;

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = _Point;
   double stop_distance = GetBrokerTradeDistance(false);

   // Pending-stop prices must also satisfy the live broker stop level.  The
   // directional normalizers prevent tick-size rounding back inside it.
   double buy_stop_price  = NormalizePriceUp(MathMax(ref_price + D1, ask + stop_distance));
   double sell_stop_price = NormalizePriceDown(MathMin(ref_price - D1, bid - stop_distance));

   double initial_lot = GetConfiguredInitialLot();

   double k_profit = GetProfitPerUnitPerLot();
   if(k_profit <= 0.0) k_profit = 100.0;
   double target_dist = T1 / k_profit;

   double buy_tp  = InpUpdateBrokerTP ? NormalizePrice(buy_stop_price + target_dist) : 0.0;
   double sell_tp = InpUpdateBrokerTP ? NormalizePrice(sell_stop_price - target_dist) : 0.0;

   // Some gold symbols require a larger minimum TP distance than T1 implies.
   // Submit the entry without a broker TP in that case.  The EA's monetary
   // basket target remains authoritative and the TP will be attached later
   // as soon as it becomes legal.
   if(buy_tp > 0.0 && buy_tp - buy_stop_price < stop_distance)
      buy_tp = 0.0;
   if(sell_tp > 0.0 && sell_stop_price - sell_tp < stop_distance)
      sell_tp = 0.0;

   LogMessage(StringFormat("Starting New Cycle. Ref Price: %.2f | Buy Stop: %.2f (TP: %.2f) | Sell Stop: %.2f (TP: %.2f) | Comment: %s",
              ref_price, buy_stop_price, buy_tp, sell_stop_price, sell_tp, EA_COMMENT));

   SetTradeMagic(M1);
   bool buy_sent = m_trade.BuyStop(initial_lot, buy_stop_price, _Symbol, 0.0, buy_tp, ORDER_TIME_GTC, 0, EA_COMMENT);
   if(!IsTradeRequestSuccessful(buy_sent))
   {
      PrintFormat("[EA ERROR] Failed to place Buy Stop at %.2f. Retcode: %u (%s), last error: %d",
                  buy_stop_price, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription(), GetLastError());
      g_state = STATE_RESETTING_CYCLE;
      return;
   }
   ulong buy_order_ticket = m_trade.ResultOrder();
   RegisterTradePlaced();

   SetTradeMagic(M2);
   bool sell_sent = m_trade.SellStop(initial_lot, sell_stop_price, _Symbol, 0.0, sell_tp, ORDER_TIME_GTC, 0, EA_COMMENT);
   if(!IsTradeRequestSuccessful(sell_sent))
   {
      PrintFormat("[EA ERROR] Failed to place Sell Stop at %.2f. Retcode: %u (%s), last error: %d",
                  sell_stop_price, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription(), GetLastError());

      // Keep initial placement atomic.  A lone pending order is unsafe and
      // was one route into the old stuck cycle state.
      if(buy_order_ticket > 0)
         m_trade.OrderDelete(buy_order_ticket);
      g_state = STATE_RESETTING_CYCLE;
      return;
   }
   RegisterTradePlaced();

   g_state = STATE_WAITING_FOR_TRIGGER;
}

void ProcessBuyBasketState()
{
   if(CheckBasketProfitTarget(POSITION_TYPE_BUY))
   {
      g_state = STATE_CLOSING_BASKET;
      CloseActiveBasket();
      return;
   }

   if(CheckBasketLossLimit(POSITION_TYPE_BUY))
   {
      g_state = STATE_CLOSING_BASKET;
      CloseActiveBasket();
      return;
   }

   int buy_pos_count = GetPositionCount(POSITION_TYPE_BUY);
   if(buy_pos_count < N && IsGovernorAllowingNewTrade())
   {
      double lowest_buy_price = GetLowestEntryPrice(POSITION_TYPE_BUY);
      if(lowest_buy_price > 0.0)
      {
         double next_grid_price = NormalizePrice(lowest_buy_price - GetGridDistancePrice(buy_pos_count));
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(ask <= next_grid_price)
         {
            if(!IsSpreadExceeded() && (TimeCurrent() - g_last_order_time >= InpMinimumDelayBetweenOrders))
            {
               double next_lot = CalculateNextGridLot(POSITION_TYPE_BUY, next_grid_price);
               if(next_lot > 0.0)
               {
                  SetTradeMagic(M1);
                  if(m_trade.Buy(next_lot, _Symbol, 0.0, 0.0, 0.0, EA_COMMENT))
                  {
                     g_last_order_time = TimeCurrent();
                     RegisterTradePlaced();
                     UpdateBrokerBasketTP(POSITION_TYPE_BUY);
                  }
                  else
                  {
                     PrintFormat("[EA ERROR] Failed to open BUY grid trade. Error: %d", GetLastError());
                  }
               }
               else
               {
                  Print("[EA WARNING] Next lot calculation returned 0.0 (MaxLot reached or invalid lot). Grid trade skipped.");
               }
            }
         }
      }
   }

   UpdateBrokerBasketTP(POSITION_TYPE_BUY);
}

void ProcessSellBasketState()
{
   if(CheckBasketProfitTarget(POSITION_TYPE_SELL))
   {
      g_state = STATE_CLOSING_BASKET;
      CloseActiveBasket();
      return;
   }

   if(CheckBasketLossLimit(POSITION_TYPE_SELL))
   {
      g_state = STATE_CLOSING_BASKET;
      CloseActiveBasket();
      return;
   }

   int sell_pos_count = GetPositionCount(POSITION_TYPE_SELL);
   if(sell_pos_count < N && IsGovernorAllowingNewTrade())
   {
      double highest_sell_price = GetHighestEntryPrice(POSITION_TYPE_SELL);
      if(highest_sell_price > 0.0)
      {
         double next_grid_price = NormalizePrice(highest_sell_price + GetGridDistancePrice(sell_pos_count));
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(bid >= next_grid_price)
         {
            if(!IsSpreadExceeded() && (TimeCurrent() - g_last_order_time >= InpMinimumDelayBetweenOrders))
            {
               double next_lot = CalculateNextGridLot(POSITION_TYPE_SELL, next_grid_price);
               if(next_lot > 0.0)
               {
                  SetTradeMagic(M2);
                  if(m_trade.Sell(next_lot, _Symbol, 0.0, 0.0, 0.0, EA_COMMENT))
                  {
                     g_last_order_time = TimeCurrent();
                     RegisterTradePlaced();
                     UpdateBrokerBasketTP(POSITION_TYPE_SELL);
                  }
                  else
                  {
                     PrintFormat("[EA ERROR] Failed to open SELL grid trade. Error: %d", GetLastError());
                  }
               }
               else
               {
                  Print("[EA WARNING] Next lot calculation returned 0.0 (MaxLot reached or invalid lot). Grid trade skipped.");
               }
            }
         }
      }
   }

   UpdateBrokerBasketTP(POSITION_TYPE_SELL);
}

double CalculateNextGridLot(ENUM_POSITION_TYPE type, double grid_entry_price)
{
   double last_lot = 0.0;
   datetime latest_time = 0;
   int pos_count = 0;
   double total_basket_lots = 0.0;
   double current_floating_profit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            pos_count++;
            double vol = m_position.Volume();
            total_basket_lots += vol;
            current_floating_profit += m_position.Profit() + m_position.Swap();

            datetime pos_time = m_position.Time();
            if(pos_time > latest_time)
            {
               latest_time = pos_time;
               last_lot = vol;
            }
         }
      }
   }

   if(last_lot <= 0.0)
      return GetConfiguredInitialLot();

   double raw_next_lot = last_lot * E1;
   double normalized_next_lot = NormalizeVolume(raw_next_lot);

   double max_broker_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(normalized_next_lot > InpMaxLot || normalized_next_lot > max_broker_vol)
   {
      PrintFormat("[EA WARNING] Calculated lot (%.2f) exceeds MaxLot limit (%.2f). Grid trade blocked.",
                  normalized_next_lot, InpMaxLot);
      return 0.0;
   }

   if(InpEnableLogs)
   {
      double basket_target_profit = (total_basket_lots + normalized_next_lot) * T1;
      PrintFormat("---------------- GRID TRADE PROGRESSION (#%d) ----------------", pos_count + 1);
      PrintFormat("Previous Lot: %.2f | Lot Multiplier: %.2f", last_lot, E1);
      PrintFormat("Raw Next Lot: %.4f | Normalized Lot: %.2f", raw_next_lot, normalized_next_lot);
      PrintFormat("Grid Entry: %.2f | Direction: %s", grid_entry_price, EnumToString(type));
      PrintFormat("Total Basket Lots (After): %.2f | Basket Positions (After): %d",
                  total_basket_lots + normalized_next_lot, pos_count + 1);
      PrintFormat("Current Floating Profit: $%.2f | Basket Target Profit: $%.2f",
                  current_floating_profit, basket_target_profit);
      PrintFormat("---------------------------------------------------------------");
   }

   return normalized_next_lot;
}

double CalculateTheoreticalTPPrice(ENUM_POSITION_TYPE type, double new_entry_price, double candidate_lot, double k_profit)
{
   double sum_volume_price = candidate_lot * new_entry_price;
   double total_volume = candidate_lot;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            sum_volume_price += m_position.Volume() * m_position.PriceOpen();
            total_volume += m_position.Volume();
         }
      }
   }

   if(total_volume <= 0.0) return 0.0;

   double break_even_price = sum_volume_price / total_volume;
   double target_dist = T1 / k_profit;

   if(type == POSITION_TYPE_BUY)
      return NormalizePrice(break_even_price + target_dist);
   else
      return NormalizePrice(break_even_price - target_dist);
}

void UpdateBrokerBasketTP(ENUM_POSITION_TYPE type)
{
   if(!InpUpdateBrokerTP) return;

   int type_index = (type == POSITION_TYPE_BUY ? 0 : 1);
   datetime now = TimeCurrent();

   // OnTradeTransaction can fire several times for one server operation.
   // Limit each basket to one TP synchronization per server second.
   if(g_last_tp_update_time[type_index] == now)
      return;
   g_last_tp_update_time[type_index] = now;

   int count = GetPositionCount(type);
   if(count == 0) return;

   double k_profit = GetProfitPerUnitPerLot();
   if(k_profit <= 0.0) k_profit = 100.0;

   double theoretical_tp = CalculateTheoreticalTPPrice(type, 0.0, 0.0, k_profit);
   if(theoretical_tp <= 0.0) return;

   string invalid_reason = "";
   if(!IsPositionTPCurrentlyValid(type, theoretical_tp, invalid_reason))
   {
      // When price has reached/crossed the theoretical level, modifying a TP
      // is illegal.  CheckBasketProfitTarget will close the basket by money.
      if(g_last_tp_skip_log_time[type_index] == 0 ||
         now - g_last_tp_skip_log_time[type_index] >= 60)
      {
         LogMessage(StringFormat("Broker TP update deferred for %s basket: %s (target %.2f).",
                    type == POSITION_TYPE_BUY ? "BUY" : "SELL", invalid_reason, theoretical_tp));
         g_last_tp_skip_log_time[type_index] = now;
      }
      return;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            double pos_tp = m_position.TakeProfit();
            double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            if(tick_size <= 0.0) tick_size = _Point;
            if(MathAbs(pos_tp - theoretical_tp) >= tick_size)
            {
               ulong ticket = m_position.Ticket();
               double sl = m_position.StopLoss();
               bool modified = m_trade.PositionModify(ticket, sl, theoretical_tp);
               if(IsTradeRequestSuccessful(modified))
               {
                  LogMessage(StringFormat("Updated Broker TP for Position #%I64u to %.2f", ticket, theoretical_tp));
               }
               else
               {
                  PrintFormat("[EA WARNING] TP update deferred for position #%I64u. Retcode: %u (%s)",
                              ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
               }
            }
         }
      }
   }
}

bool CheckBasketLossLimit(ENUM_POSITION_TYPE type)
{
   if(BasketMaxLoss <= 0.0) return false;

   double total_profit = 0.0;
   int pos_count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            total_profit += m_position.Profit() + m_position.Swap();
            pos_count++;
         }
      }
   }

   if(pos_count == 0) return false;

   if(total_profit <= -BasketMaxLoss)
   {
      LogMessage(StringFormat("BASKET STOP-LOSS TRIGGERED! Floating P&L: $%.2f | Limit: -$%.2f | Closing basket.",
                 total_profit, BasketMaxLoss));
      return true;
   }
   return false;
}

bool CheckBasketProfitTarget(ENUM_POSITION_TYPE type)
{
   double total_profit = 0.0;
   double total_volume = 0.0;
   int pos_count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            total_profit += m_position.Profit() + m_position.Swap();
            total_volume += m_position.Volume();
            pos_count++;
         }
      }
   }

   if(pos_count == 0) return false;

   double required_profit = total_volume * T1;

   if(total_profit >= required_profit)
   {
      LogMessage(StringFormat("BASKET TARGET REACHED! Floating Profit: $%.2f | Required: $%.2f | Total Lots: %.2f",
                 total_profit, required_profit, total_volume));
      return true;
   }

   return false;
}

void CloseActiveBasket()
{
   LogMessage("Closing all positions in active basket...");

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()))
         {
            ulong ticket = m_position.Ticket();
            if(!m_trade.PositionClose(ticket))
            {
               PrintFormat("[EA ERROR] Failed to close position #%I64u. Error: %d", ticket, GetLastError());
            }
         }
      }
   }

   CancelAllPendingOrders();

   g_state = STATE_RESETTING_CYCLE;
}

void ProcessResettingCycleState()
{
   int pos_count = GetPositionCount();
   int ord_count = GetPendingOrderCount();

   if(pos_count == 0 && ord_count == 0)
   {
      g_state = STATE_WAITING_FOR_TRIGGER;
      if(CanStartNewCycle())
      {
         LogMessage("Cycle reset verified. Starting a new allowed cycle.");
         PlaceInitialPendingOrders();
      }
   }
   else
   {
      // Self-heal if a transaction arrived while the cycle was resetting.
      // The previous implementation did nothing here and could remain in
      // STATE_RESETTING_CYCLE indefinitely.
      ReconstructState();
   }
}

//+------------------------------------------------------------------+
//| UTILITY & HELPERS                                                 |
//+------------------------------------------------------------------+
int GetPositionCount(ENUM_POSITION_TYPE type = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()))
         {
            if(type == -1 || m_position.PositionType() == type)
               count++;
         }
      }
   }
   return count;
}

int GetPendingOrderCount()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i))
      {
         if(m_order.Symbol() == _Symbol && IsOurMagic(m_order.Magic()))
            count++;
      }
   }
   return count;
}

double GetLowestEntryPrice(ENUM_POSITION_TYPE type)
{
   double lowest = 999999.0;
   bool found = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            if(m_position.PriceOpen() < lowest)
            {
               lowest = m_position.PriceOpen();
               found = true;
            }
         }
      }
   }
   return found ? lowest : 0.0;
}

double GetHighestEntryPrice(ENUM_POSITION_TYPE type)
{
   double highest = 0.0;
   bool found = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            if(m_position.PriceOpen() > highest)
            {
               highest = m_position.PriceOpen();
               found = true;
            }
         }
      }
   }
   return found ? highest : 0.0;
}

void CancelPendingOrders(ENUM_ORDER_TYPE order_type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i))
      {
         if(m_order.Symbol() == _Symbol && IsOurMagic(m_order.Magic()) &&
            m_order.OrderType() == order_type)
         {
            ulong ticket = m_order.Ticket();
            m_trade.OrderDelete(ticket);
         }
      }
   }
}

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i))
      {
         if(m_order.Symbol() == _Symbol && IsOurMagic(m_order.Magic()))
         {
            ulong ticket = m_order.Ticket();
            m_trade.OrderDelete(ticket);
         }
      }
   }
}

void RegisterTradePlaced()
{
   g_last_order_time = TimeCurrent();
}

bool IsTradeRequestSuccessful(const bool method_result)
{
   if(!method_result)
      return false;

   uint retcode = m_trade.ResultRetcode();
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_DONE_PARTIAL ||
           retcode == TRADE_RETCODE_PLACED ||
           retcode == TRADE_RETCODE_NO_CHANGES);
}

double GetBrokerTradeDistance(const bool include_freeze_level)
{
   long stops_points = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_points = include_freeze_level
                        ? SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)
                        : 0;
   long required_points = (long)MathMax((double)stops_points, (double)freeze_points);

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = _Point;

   // One extra tick protects against equality and price movement between the
   // local validation and the server-side request check.
   return required_points * _Point + tick_size;
}

bool IsPositionTPCurrentlyValid(const ENUM_POSITION_TYPE type,
                                const double tp,
                                string &reason)
{
   if(tp <= 0.0 || !MathIsValidNumber(tp))
   {
      reason = "invalid calculated price";
      return false;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double required_distance = GetBrokerTradeDistance(true);

   if(type == POSITION_TYPE_BUY && tp <= bid + required_distance)
   {
      reason = StringFormat("BUY TP must be above Bid %.2f by more than %.2f", bid, required_distance);
      return false;
   }
   if(type == POSITION_TYPE_SELL && tp >= ask - required_distance)
   {
      reason = StringFormat("SELL TP must be below Ask %.2f by more than %.2f", ask, required_distance);
      return false;
   }

   return true;
}

bool IsGovernorAllowingNewTrade()
{
   double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   // margin_level is 0 when no positions are open — allow freely in that case
   if(margin_level > 0.0 && margin_level < InpMinMarginLevel)
   {
      if(InpEnableLogs)
         PrintFormat("[GOVERNOR] New grid trade blocked: Margin Level %.1f%% below minimum %.1f%%",
                     margin_level, InpMinMarginLevel);
      return false;
   }
   return true;
}

double GetProfitPerUnitPerLot()
{
   double profit = 0.0;
   double price1 = 1000.0;
   double price2 = 1001.0;

   if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, price1, price2, profit) && profit > 0.0)
   {
      return profit;
   }

   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size > 0.0 && tick_val > 0.0)
   {
      return (1.0 / tick_size) * tick_val;
   }

   return 100.0;
}

bool IsSpreadExceeded()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_spread = ask - bid;

   if(current_spread > P1)
   {
      if(InpEnableLogs)
         PrintFormat("[EA SPREAD FILTER] Current spread (%.2f) exceeds MaxSpread limit (%.2f). Entry delayed.",
                     current_spread, P1);
      return true;
   }
   return false;
}

double NormalizePrice(double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = _Point;
   return MathRound(price / tick_size) * tick_size;
}

double NormalizePriceUp(double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = _Point;
   return MathCeil(price / tick_size - 1e-9) * tick_size;
}

double NormalizePriceDown(double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = _Point;
   return MathFloor(price / tick_size + 1e-9) * tick_size;
}

double NormalizeVolume(double volume)
{
   double min_vol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step_vol <= 0.0) step_vol = 0.01;

   double normalized = MathRound((volume - min_vol) / step_vol) * step_vol + min_vol;
   if(normalized < min_vol) normalized = min_vol;
   if(normalized > max_vol) normalized = max_vol;
   if(normalized > InpMaxLot) normalized = InpMaxLot;

   return MathRound((normalized - min_vol) / step_vol) * step_vol + min_vol;
}

double GetConfiguredInitialLot()
{
   double lot = V1;
   if(R1 > 0.0)
      lot *= R1;
   return NormalizeVolume(lot);
}

double GetGridDistancePrice(const int current_position_count)
{
   int additions_already_open = (current_position_count > 1 ? current_position_count - 1 : 0);
   return (additions_already_open < P2 ? S1 : S2);
}

void LogMessage(string message)
{
   if(InpEnableLogs)
   {
      PrintFormat("[GOLD-PIP MINER EA V6] %s", message);
   }
}

bool IsTradingSessionOpen()
{
   if(!F1)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   int current_minutes = tm.hour * 60 + tm.min;
   int start_minutes   = T2 * 60 + T3;
   int end_minutes     = T4 * 60 + T5;

   if(start_minutes == end_minutes)
      return true;

   if(start_minutes < end_minutes)
      return (current_minutes >= start_minutes && current_minutes <= end_minutes);

   return (current_minutes >= start_minutes || current_minutes <= end_minutes);
}

double GetTodayRealizedProfit()
{
   datetime now = TimeCurrent();
   MqlDateTime tm;
   TimeToStruct(now, tm);
   tm.hour = 0;
   tm.min  = 0;
   tm.sec  = 0;
   datetime day_start = StructToTime(tm);

   if(!HistorySelect(day_start, now))
      return 0.0;

   double result = 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(!IsOurMagic(magic))
         continue;

      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(symbol != _Symbol)
         continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      result += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      result += HistoryDealGetDouble(ticket, DEAL_SWAP);
      result += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return result;
}

bool IsDailyTargetReached()
{
   if(!F3 || DT1 <= 0.0)
      return false;
   return (GetTodayRealizedProfit() >= DT1);
}

datetime GetCalendarServerTime()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   return now;
}

void ResetNewsCache(const bool calendar_available = true)
{
   g_news_blocked       = false;
   g_calendar_available  = calendar_available;
   g_next_news_time      = 0;
   g_next_news_name      = calendar_available ? "No scheduled high-impact USD news" : "MQL5 calendar unavailable";
   g_active_news_name    = "";
}

bool IsSelectedNewsImportance(const int importance)
{
   if(InpNewsMode == N2)
      return (importance == CALENDAR_IMPORTANCE_HIGH);
   if(InpNewsMode == N1)
      return (importance == CALENDAR_IMPORTANCE_MODERATE || importance == CALENDAR_IMPORTANCE_HIGH);
   return true;
}

void UpdateNewsState(const bool force_refresh = false)
{
   if(!F4)
   {
      ResetNewsCache(true);
      g_next_news_name = "News filter disabled";
      return;
   }

   datetime now = GetCalendarServerTime();
   int refresh_seconds = (InpNewsRefreshSeconds < 5 ? 5 : InpNewsRefreshSeconds);
   int before_minutes = (T6 < 0 ? 0 : T6);
   int after_minutes  = (T7 < 0 ? 0 : T7);
   int lookahead_days = (InpNewsLookAheadDays < 1 ? 1 : InpNewsLookAheadDays);

   if(!force_refresh && g_next_news_time > 0)
   {
      bool cached_window = (now >= g_next_news_time - before_minutes * 60 &&
                            now <= g_next_news_time + after_minutes * 60);
      g_news_blocked = cached_window;
      g_active_news_name = cached_window ? g_next_news_name : "";

      if(now <= g_next_news_time + after_minutes * 60 &&
         g_last_news_scan > 0 && (now - g_last_news_scan) < refresh_seconds)
         return;
   }
   else if(!force_refresh && g_last_news_scan > 0 && (now - g_last_news_scan) < refresh_seconds)
   {
      return;
   }

   g_last_news_scan = now;
   ResetNewsCache(true);

   datetime from_time = now - after_minutes * 60;
   datetime to_time   = now + lookahead_days * 86400;

   MqlCalendarValue values[];
   ResetLastError();
   int count = CalendarValueHistory(values, from_time, to_time, NULL, "USD");
   if(count < 0)
   {
      ResetNewsCache(false);
      if(InpEnableLogs)
         PrintFormat("[GOLD-PIP MINER EA V6] MQL5 calendar query failed. Error: %d", GetLastError());
      return;
   }

   datetime nearest_upcoming_time = 0;
   string nearest_upcoming_name = "";
   datetime active_event_time = 0;
   string active_event_name = "";

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event))
         continue;

      if(!IsSelectedNewsImportance(event.importance))
         continue;

      datetime event_time = values[i].time;
      if(event_time <= 0)
         continue;

      bool inside_block_window = (now >= event_time - before_minutes * 60 &&
                                  now <= event_time + after_minutes * 60);

      if(inside_block_window)
      {
         long event_distance = (event_time >= now ? (long)(event_time - now) : (long)(now - event_time));
         long active_distance = 0;
         if(active_event_time > 0)
            active_distance = (active_event_time >= now ? (long)(active_event_time - now) : (long)(now - active_event_time));

         if(active_event_time == 0 || event_distance < active_distance)
         {
            active_event_time = event_time;
            active_event_name = event.name;
         }
      }

      if(event_time > now && (nearest_upcoming_time == 0 || event_time < nearest_upcoming_time))
      {
         nearest_upcoming_time = event_time;
         nearest_upcoming_name = event.name;
      }
   }

   if(active_event_time > 0)
   {
      g_news_blocked     = true;
      g_active_news_name = active_event_name;
      g_next_news_time    = active_event_time;
      g_next_news_name    = active_event_name;
   }
   else if(nearest_upcoming_time > 0)
   {
      g_next_news_time = nearest_upcoming_time;
      g_next_news_name = nearest_upcoming_name;
   }
}

bool IsNewsWindowBlocked()
{
   UpdateNewsState(false);
   return (F4 && g_news_blocked);
}

bool CanStartNewCycle()
{
   if(!IsTradingSessionOpen())
      return false;
   if(IsDailyTargetReached())
      return false;
   if(IsNewsWindowBlocked())
      return false;
   if(!IsGovernorAllowingNewTrade())
      return false;
   return true;
}

double GetCurrentDrawdownPercent()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0.0 || equity >= balance)
      return 0.0;

   return ((balance - equity) / balance) * 100.0;
}

bool IsMaxDrawdownReached()
{
   if(!InpEnableMaxDDProtection)
      return false;

   double current_dd = GetCurrentDrawdownPercent();
   return (current_dd >= InpMaxDrawdownPercent);
}

void TriggerMaxDDEmergency()
{
   if(g_max_dd_emergency_active) return;

   g_max_dd_emergency_active = true;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd_money = (balance > equity) ? (balance - equity) : 0.0;
   double dd_pct   = GetCurrentDrawdownPercent();

   Print("===============================================================");
   Print("         MAX DRAWDOWN PROTECTION TRIGGERED!                    ");
   PrintFormat("Account Balance: $%.2f | Account Equity: $%.2f", balance, equity);
   PrintFormat("Drawdown Amount: $%.2f | Drawdown Percent: %.2f%% (Limit: %.2f%%)",
               dd_money, dd_pct, InpMaxDrawdownPercent);
   Print("Action: Blocking entries, deleting EA orders, closing EA positions.");
   Print("===============================================================");
}

void ProcessMaxDDEmergency()
{
   CancelAllPendingOrders();
   CloseAllEAPositions();

   int open_positions = GetPositionCount();
   int pending_orders = GetPendingOrderCount();

   if(open_positions == 0 && pending_orders == 0)
   {
      g_max_dd_emergency_active = false;

      if(InpAfterMaxDD == DD_CONTINUE_TRADING)
      {
         LogMessage("===============================================================");
         LogMessage("Max DD liquidation completed. AfterMaxDD: CONTINUE TRADING.");
         LogMessage("Old basket cleared. Lot progression reset. Starting fresh trading cycle.");
         LogMessage("===============================================================");
         g_state = STATE_RESETTING_CYCLE;
      }
      else
      {
         g_trading_stopped_by_max_dd = true;
         LogMessage("===============================================================");
         LogMessage("Max DD liquidation completed. AfterMaxDD: STOP TRADING.");
         LogMessage("EA trading is DISABLED for this session.");
         LogMessage("Detach and attach the EA again to resume trading.");
         LogMessage("===============================================================");
      }
   }
   else
   {
      if(InpEnableLogs)
         PrintFormat("[MAX DD EMERGENCY] Liquidation in progress... Remaining EA positions: %d, orders: %d",
                     open_positions, pending_orders);
   }
}

void CloseAllEAPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()))
         {
            ulong ticket = m_position.Ticket();
            if(!m_trade.PositionClose(ticket))
            {
               PrintFormat("[EA ERROR] Emergency close failed for position #%I64u. Error: %d",
                           ticket, GetLastError());
            }
         }
      }
   }
}

//===================================================================
//  SOVEREIGN DASHBOARD IV — THEME (Crimson / Gold / Obsidian palette,
//  extended with blend-capable gradient tiers plus a new azure/violet
//  "neural" accent range used by the Confidence Arc and Data-Rain column)
//===================================================================
#define C_OBSIDIAN      C'9,8,7'
#define C_ONYX          C'15,13,11'
#define C_CHARCOAL      C'22,19,16'
#define C_CHARCOAL2     C'28,24,20'
#define C_CRIMSON       C'150,18,26'
#define C_DEEPCRIMSON   C'96,12,18'
#define C_BLOOD         C'58,8,12'
#define C_EMBER         C'205,60,46'
#define C_GOLD          C'196,161,63'
#define C_GOLDBRIGHT    C'255,214,110'
#define C_GOLDDIM       C'120,98,42'
#define C_BRASS         C'150,124,58'
#define C_IVORY         C'224,214,192'
#define C_SLATE         C'118,110,98'
#define C_STEEL         C'70,64,56'
#define C_WHITE         C'236,230,215'
#define C_GREEN_OK      C'150,196,110'
#define C_RED_BAD       C'205,60,46'
#define C_SHADOW        C'4,3,3'
#define C_AZURE         C'86,140,168'
#define C_AZUREDIM      C'46,80,98'
#define C_VIOLET        C'128,96,168'
#define C_NEONMINT      C'110,214,180'
#define C_NEONMINTDIM   C'50,96,84'

// Vertex-IQ heat tiers: obsidian (cold) -> crimson -> gold (hot)
#define VTX_T0  C'9,8,7'
#define VTX_T1  C'26,10,10'
#define VTX_T2  C'46,14,14'
#define VTX_T3  C'70,16,16'
#define VTX_T4  C'96,20,18'
#define VTX_T5  C'124,26,20'
#define VTX_T6  C'150,45,24'
#define VTX_T7  C'178,80,30'
#define VTX_T8  C'196,120,40'
#define VTX_T9  C'214,160,60'
#define VTX_T10 C'255,214,110'

// Volatility-gauge tiers: azure (calm) -> violet -> crimson (extreme)
#define VOL_T0  C'9,8,7'
#define VOL_T1  C'20,28,34'
#define VOL_T2  C'30,48,58'
#define VOL_T3  C'46,80,98'
#define VOL_T4  C'70,90,130'
#define VOL_T5  C'96,90,150'
#define VOL_T6  C'128,96,168'
#define VOL_T7  C'160,86,150'
#define VOL_T8  C'190,70,110'
#define VOL_T9  C'205,60,46'
#define VOL_T10 C'255,120,70'

// Confidence-arc tiers: crimson (low conviction) -> gold -> neon-mint (high conviction)
#define CONF_T0  C'96,12,18'
#define CONF_T1  C'150,18,26'
#define CONF_T2  C'178,80,30'
#define CONF_T3  C'196,120,40'
#define CONF_T4  C'196,161,63'
#define CONF_T5  C'214,160,60'
#define CONF_T6  C'255,214,110'
#define CONF_T7  C'190,214,150'
#define CONF_T8  C'150,214,170'
#define CONF_T9  C'110,214,180'

#define DB_PREFIX  "GPM7Q_"     // Main Sovereign dashboard
#define VX_PREFIX  "GPM7Q_VX_"  // Vertex-IQ compact heat-matrix panel

//--- Typography: clear Arial across the whole interface, sized up for readability
#define FS_TITLE     12
#define FS_SUBTITLE  7
#define FS_LIVE      9
#define FS_SECTION   9
#define FS_LABEL     10
#define FS_VALUE     10
#define FS_BAL_CAP   9
#define FS_BAL_VAL   17
#define FS_STRIP     10
#define FS_FOOTER    8
#define FS_VX_HDR    11
#define FS_VX_COL    7
#define FS_VX_BAND   7
#define FS_VX_FOOT   8
#define FS_LADDER    9
#define FS_SPARKHDR  8
#define FS_RISKHDR   8
#define FS_RISKVAL   9
#define FS_TICKER    9
#define FS_CLOCK_TIME 15
#define FS_CLOCK_DATE 8
#define FS_PULSE_HDR  8
#define FS_VOL_HDR    8
#define FS_VOL_VAL    9
#define FS_CONF_HDR   8
#define FS_CONF_VAL   12
#define FS_RAIN       7

//--- Dashboard geometry / animation state
int      DB_X = 6, DB_Y = 6;
int      DashboardWidth  = 1320;
int      DashboardHeight = 412;
int      AnimationTick   = 0;
int      ScanLineTick    = 0;
int      ScanLineTickBottom = 0;
int      ScanLineTickLeft   = 0;
int      ScanLineTickRight  = 0;

double   PeakEquity      = 0.0;
double   BullPressure    = 0.0;
double   BearPressure    = 0.0;
int      PressureSmooth  = 0;

int      g_history_deals_scanned = -1;
int      g_win_count    = 0;
int      g_loss_count   = 0;
int      g_total_closed = 0;
double   g_best_trade   = 0.0;
double   g_worst_trade  = 0.0;
int      g_streak_type  = 0;
int      g_streak_count = 0;
double   g_gross_profit = 0.0;
double   g_gross_loss   = 0.0;

double   VX_Grid[8][32];
double   VX_GridTarget[8][32];
double   VX_ColBase[8];
int      VX_AnimTick     = 0;
int      VX_WaveOffset   = 0;
int      VX_ParticleRow[4];
int      VX_ParticleCol[4];
double   VX_ParticleHeat[4];
int      VX_SweepTick    = 0;
int      VX_SweepTickV   = 0;

int      VX_X = 0, VX_Y = 0, VX_W = 0, VX_H = 0;
int      VX_HeaderH = 16, VX_FooterH = 14, VX_BandH = 9, VX_BandGap = 2;
int      VX_LabelW = 24, VX_CellW = 10;
int      VX_Cols = 6, VX_Rows = 16;

int      g_rsi_handle = INVALID_HANDLE;
int      g_atr_handle = INVALID_HANDLE;

#define  SPIN_DOTS 8
#define  SPIN_DOTS_OUTER 12
int      g_spin_cx = 0, g_spin_cy = 0, g_spin_radius = 9, g_spin_radius_outer = 16;
int      g_spin_x[SPIN_DOTS];
int      g_spin_y[SPIN_DOTS];
int      g_spin_ox[SPIN_DOTS_OUTER];
int      g_spin_oy[SPIN_DOTS_OUTER];
int      g_spin_index = 0;
int      g_spin_outer_index = 0;

#define  SPIN_DOTS_HALO 16
int      g_spin_radius_halo = 23;
int      g_spin_hx[SPIN_DOTS_HALO];
int      g_spin_hy[SPIN_DOTS_HALO];
int      g_spin_halo_index = 0;

int      g_hdrscan_pos = 0;
int      g_hdrscan_dir = 1;

#define  HEX_DOTS 6
int      g_hex_cx = 0, g_hex_cy = 0, g_hex_radius = 7;
int      g_hex_x[HEX_DOTS];
int      g_hex_y[HEX_DOTS];
int      g_hex_index = 0;
double   g_hex_pulse = 0.0;

#define  SPARK_COUNT 60
double   g_spark_values[SPARK_COUNT];
int      g_spark_filled   = 0;
int      g_spark_x        = 0;
int      g_spark_base_y   = 0;
int      g_spark_max_h    = 34;
int      g_spark_bar_w    = 13;
int      g_spark_bar_gap  = 2;
int      g_spark_tick     = 0;

#define  LADDER_LEVELS 4
double   g_ladder_pulse    = 0.0;

#define  RISK_SEGS 10
int      g_risk_x = 0, g_risk_base_y = 0, g_risk_seg_h = 12, g_risk_seg_gap = 2;
double   g_risk_smoothed = 0.0;

int      g_vol_x = 0, g_vol_base_y = 0;
#define  VOL_SEGS 10
double   g_vol_smoothed = 0.0;
double   g_vol_baseline = 0.0;
int      g_vol_baseline_count = 0;

#define  TICKER_SLOTS 5
string   g_ticker_msgs[TICKER_SLOTS];
int      g_ticker_index = 0;
int      g_ticker_hold_ticks = 0;
int      g_ticker_fade_ticks = 0;
bool     g_ticker_fading = false;

string   g_dow_names[7] = {"SUN","MON","TUE","WED","THU","FRI","SAT"};

#define  PULSE_COUNT 14

double   g_corner_glow_phase = 0.0;

#define  CHASE_TRAIL 4

//--- NEW: Confidence Arc (multi-factor composite: trend alignment, RSI bias,
//    volatility regime, session status) rendered as a 12-segment radial arc.
#define  CONF_SEGS 12
int      g_conf_x = 0, g_conf_y = 0;
double   g_conf_smoothed = 0.5;

//--- NEW: Data-Rain ambient column — a thin vertical strip of falling
//    "digits" (rendered as small tick glyphs) that reinforces the
//    AI/quant identity without competing for attention with real data.
#define  RAIN_COLS 3
#define  RAIN_DROPS_PER_COL 6
int      g_rain_x[RAIN_COLS];
int      g_rain_y[RAIN_COLS*RAIN_DROPS_PER_COL];
double   g_rain_speed[RAIN_COLS*RAIN_DROPS_PER_COL];
int      g_rain_top = 0, g_rain_bottom = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{

 //--- create the label object
   ObjectCreate(0, "c", OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, "c", OBJPROP_CORNER,     1);
   ObjectSetInteger(0, "c", OBJPROP_XDISTANCE,  670);
   ObjectSetInteger(0, "c", OBJPROP_YDISTANCE,  220);

   ObjectSetString (0, "c", OBJPROP_TEXT,       "%");
   ObjectSetString (0, "c", OBJPROP_FONT,       "Webdings");
   ObjectSetInteger(0, "c", OBJPROP_FONTSIZE,   60);
   ObjectSetInteger(0, "c", OBJPROP_COLOR,      C'28,24,20');

   //--- force it to render ON TOP (foreground), not behind the dashboard
   ObjectSetInteger(0, "c", OBJPROP_BACK,       false);
   ObjectSetInteger(0, "c", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "c", OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, "c", OBJPROP_ZORDER,     1000); // high z-order = drawn above other objects


   g_max_dd_emergency_active   = false;
   g_trading_stopped_by_max_dd = false;

   long margin_mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(margin_mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      PrintFormat("[EA ERROR] Account must be in HEDGING mode! Current mode ID: %d", margin_mode);
      return INIT_FAILED;
   }

   if(V1 <= 0.0 || D1 <= 0.0 || S1 <= 0.0 || S2 <= 0.0 || M1 == M2 ||
      T1 <= 0.0 || E1 <= 0.0 || N < 1 || P2 < 0)
   {
      Print("[EA ERROR] Invalid input parameters. Inputs must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(T2 < 0 || T2 > 23 || T4 < 0 || T4 > 23 || T3 < 0 || T3 > 59 || T5 < 0 || T5 > 59 ||
      T6 < 0 || T7 < 0)
   {
      Print("[EA ERROR] Invalid session or news-filter time.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpEnableMaxDDProtection && (InpMaxDrawdownPercent <= 0.0 || InpMaxDrawdownPercent >= 100.0))
   {
      Print("[EA ERROR] MaxDrawdownPercent must be strictly between 0.0 and 100.0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ArrowCleanupSeconds < 1)
   {
      Print("[EA ERROR] ArrowCleanupSeconds must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
   }

   m_trade.SetExpertMagicNumber(M1);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(_Symbol);

   ReconstructState();
   UpdateNewsState(true);

   PeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_rsi_handle = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   g_atr_handle = iATR(_Symbol, PERIOD_H1, 14);

   ArrayInitialize(g_spark_values, 0.0);
   g_spark_filled = 0;

   ApplyChartTheme();
   ApplyTradeArrowVisibility();

   if(ShowDashboard)
   {
      BuildDashboard();
      BuildSpinner();
      BuildHexCore();
      if(ShowAdvancedPanels)
      {
         BuildSparkline();
         BuildGridLadder();
         BuildRiskMeter();
         BuildTicker();
      }
      if(ShowSessionClock)     BuildSessionClock();
      if(ShowMarketPulse)      BuildMarketPulse();
      if(ShowVolatilityGauge)  BuildVolatilityGauge();
      if(ShowConfidenceArc)    BuildConfidenceArc();
      if(ShowDataRain)         BuildDataRain();
   }
   if(ShowVertexIQ)  { InitVertexData(); BuildVertexIQ(); }

   LogMessage(StringFormat("EA Initialized successfully. Symbol: %s | BUY Magic: %I64u | SELL Magic: %I64u | State: %s | Max DD Protection: %s (%.2f%%)",
              _Symbol, M1, M2, EnumToString(g_state),
              InpEnableMaxDDProtection ? "ENABLED" : "DISABLED", InpMaxDrawdownPercent));

   Print("===================================================");
   Print("  GOLD-PIP MINER EA V6 (MQ5) INITIALIZED");
   Print("  Theme            : SOVEREIGN GOLD-BULLET IV (CRIMSON/GOLD/OBSIDIAN/NEON-MINT)");
   Print("  Dashboard        : Hybrid advanced layout | magnified balance card | "+IntegerToString(DashboardWidth)+"x"+IntegerToString(DashboardHeight));
   Print("  Sub-Panels       : "+(ShowAdvancedPanels ? "ON (sparkline, grid ladder, risk thermometer, ticker, tri-ring spinner)" : "OFF"));
   Print("  Extra Panels     : Clock="+(ShowSessionClock?"ON":"OFF")+" | Pulse="+(ShowMarketPulse?"ON":"OFF")+" | VolGauge="+(ShowVolatilityGauge?"ON":"OFF")+" | ConfArc="+(ShowConfidenceArc?"ON":"OFF")+" | DataRain="+(ShowDataRain?"ON":"OFF"));
   Print("  Vertex-IQ Panel  : "+(ShowVertexIQ ? "ON (embedded beneath Grid Ladder Projector, dual-sweep)" : "OFF")+" | "+IntegerToString(VertexCols)+" bands x "+IntegerToString(VertexRows)+" cells");
   Print("  Chart Arrows     : "+(ShowTradeArrows ? "SHOWN" : "HIDDEN")+" | AutoClean="+(AutoCleanArrows ? "ON every "+IntegerToString(ArrowCleanupSeconds)+"s" : "OFF")+" (chart display only - broker history is unaffected)");
   Print("  Account Mode     : HEDGING CONFIRMED");
   Print("===================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteAllDashboard();
   if(g_rsi_handle != INVALID_HANDLE) IndicatorRelease(g_rsi_handle);
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Comment("");
   LogMessage(StringFormat("EA Deinitialized. Reason code: %d", reason));
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_trading_stopped_by_max_dd)
   {
      RefreshDashboard();
      MaybeCleanupArrows();
      return;
   }

   if(g_max_dd_emergency_active)
   {
      ProcessMaxDDEmergency();
      RefreshDashboard();
      MaybeCleanupArrows();
      return;
   }

   if(IsMaxDrawdownReached())
   {
      TriggerMaxDDEmergency();
      ProcessMaxDDEmergency();
      RefreshDashboard();
      MaybeCleanupArrows();
      return;
   }

   // Account state is the source of truth.  This watchdog closes the event
   // timing gap that previously left the EA in BUY/SELL basket state after
   // its final position had already closed.  Reattaching appeared to fix the
   // problem only because OnInit called the same reconstruction routine.
   ReconstructState();

   switch(g_state)
   {
      case STATE_INIT:
         break;

      case STATE_WAITING_FOR_TRIGGER:
         ProcessWaitingForTriggerState();
         break;

      case STATE_BUY_BASKET_ACTIVE:
         ProcessBuyBasketState();
         break;

      case STATE_SELL_BASKET_ACTIVE:
         ProcessSellBasketState();
         break;

      case STATE_CLOSING_BASKET:
         CloseActiveBasket();
         break;

      case STATE_RESETTING_CYCLE:
         ProcessResettingCycleState();
         break;
   }

   RefreshDashboard();
   MaybeCleanupArrows();
}

//+------------------------------------------------------------------+
//| Trade Transaction handler for fast real-time event detection     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(g_trading_stopped_by_max_dd) return;

   if(g_max_dd_emergency_active)
   {
      ProcessMaxDDEmergency();
      return;
   }

   if(IsMaxDrawdownReached())
   {
      TriggerMaxDDEmergency();
      ProcessMaxDDEmergency();
      return;
   }

   if(trans.type == TRADE_TRANSACTION_ORDER_ADD ||
      trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_HISTORY_ADD ||
      trans.type == TRADE_TRANSACTION_DEAL_ADD ||
      trans.type == TRADE_TRANSACTION_POSITION)
   {
      ReconstructState();
      // A trade-level event just fired (open/close/modify). If arrow
      // cleanup is enabled, sweep on the next tick pass rather than here,
      // so we don't fight the terminal while it is still drawing the marker.
   }
}

//===================================================================
//  CHART TRADE-ARROW DISPLAY MANAGEMENT
//  ---------------------------------------------------------------
//  MT5 draws its own buy/sell/tp/sl markers directly on the chart as
//  built-in chart objects. This section only toggles/removes THOSE
//  VISUAL OBJECTS. It never touches HistorySelect data, deal records,
//  the broker's server-side trade history, or the account statement -
//  none of that is chart-object data and none of it can be altered
//  by an EA. Use ShowTradeArrows to hide markers outright, or
//  AutoCleanArrows to periodically sweep a busy grid-EA chart clean.
//===================================================================
void ApplyTradeArrowVisibility()
{
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, ShowTradeArrows);
   ChartSetInteger(0, CHART_DRAG_TRADE_LEVELS, ShowTradeArrows);
   if(!ShowTradeArrows)
      SweepChartTradeMarkers();
   ChartRedraw();
}

// Removes the terminal's auto-generated trade marker OBJECTS from the
// chart (their naming pattern begins with "#"). This is a pure display
// sweep of the current chart window; it does not delete deals, orders,
// or any broker-side record, and a fresh marker will simply reappear
// on the next trade event or chart re-render if ShowTradeArrows is on.
void SweepChartTradeMarkers()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i, -1, -1);
      if(StringLen(nm) > 0 && StringGetCharacter(nm, 0) == '#')
         ObjectDelete(0, nm);
   }
}

void MaybeCleanupArrows()
{
   if(!AutoCleanArrows) return;
   datetime now = TimeCurrent();
   if(now - g_last_arrow_cleanup < ArrowCleanupSeconds) return;
   g_last_arrow_cleanup = now;
   SweepChartTradeMarkers();
}

//===================================================================
//  CHART THEME — SOVEREIGN CRIMSON / GOLD / OBSIDIAN
//===================================================================
void ApplyChartTheme()
{
   ChartSetInteger(0, CHART_COLOR_BACKGROUND,    C_OBSIDIAN);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND,    C_SLATE);
   ChartSetInteger(0, CHART_COLOR_GRID,          C_ONYX);
   ChartSetInteger(0, CHART_COLOR_VOLUME,        C_STEEL);
   ChartSetInteger(0, CHART_COLOR_CHART_UP,      C_CHARCOAL);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN,    C_BLOOD);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL,   C_GOLD);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR,   C_CRIMSON);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE,    C_GOLDBRIGHT);
   ChartSetInteger(0, CHART_COLOR_BID,           C_SLATE);
   ChartSetInteger(0, CHART_COLOR_ASK,           C_IVORY);
   ChartSetInteger(0, CHART_COLOR_LAST,          C_WHITE);
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL,    C_CRIMSON);
   ChartSetInteger(0, CHART_MODE, CHART_CANDLES);
   ChartRedraw();
}

//===================================================================
//  COLOR BLEND HELPER
//===================================================================
color BlendColor(const color c1, const color c2, double t)
{
   if(t < 0.0) t = 0.0;
   if(t > 1.0) t = 1.0;

   int r1 = (int)(c1 & 0xFF);
   int g1 = (int)((c1 >> 8) & 0xFF);
   int b1 = (int)((c1 >> 16) & 0xFF);

   int r2 = (int)(c2 & 0xFF);
   int g2 = (int)((c2 >> 8) & 0xFF);
   int b2 = (int)((c2 >> 16) & 0xFF);

   int r = (int)MathRound(r1 + (r2 - r1) * t);
   int g = (int)MathRound(g1 + (g2 - g1) * t);
   int b = (int)MathRound(b1 + (b2 - b1) * t);

   return (color)(r | (g << 8) | (b << 16));
}

double BreathWave(double phase)
{
   return (MathSin(phase) + 1.0) * 0.5;
}

//===================================================================
//  OBJECT HELPERS
//===================================================================
void CreateBackgroundPanelLower(string name, int x, int y, int w, int h, color bg, color border)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void CreateLabelLower(string name, string text, int x, int y, int fontSize, color clr, bool bold=false)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void UpdLbl(string name, string text, color clr)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }
}

void UpdRect(string name, color clr)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_COLOR,   clr);
   }
}

void CreateCornerBrackets(int w, int h)
{
   int len = 24;
   CreateBackgroundPanelLower(DB_PREFIX+"brk_bl_h", DB_X, DB_Y, len, 2, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_bl_v", DB_X, DB_Y, 2, len, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_br_h", DB_X+w-len, DB_Y, len, 2, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_br_v", DB_X+w-2,   DB_Y, 2, len, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_tl_h", DB_X, DB_Y+h-2, len, 2, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_tl_v", DB_X, DB_Y+h-len, 2, len, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_tr_h", DB_X+w-len, DB_Y+h-2, len, 2, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"brk_tr_v", DB_X+w-2,   DB_Y+h-len, 2, len, C_GOLD, C_OBSIDIAN);

   CreateBackgroundPanelLower(DB_PREFIX+"glow_bl", DB_X+4,     DB_Y+4,     4, 4, C_GOLDDIM, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"glow_br", DB_X+w-8,   DB_Y+4,     4, 4, C_GOLDDIM, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"glow_tl", DB_X+4,     DB_Y+h-8,   4, 4, C_GOLDDIM, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"glow_tr", DB_X+w-8,   DB_Y+h-8,   4, 4, C_GOLDDIM, C_OBSIDIAN);

   for(int i = 0; i < CHASE_TRAIL; i++)
   {
      CreateBackgroundPanelLower(DB_PREFIX+"scanline_"+IntegerToString(i),        DB_X+2, DB_Y+h-40, 14, 2, C_GOLD,   C_OBSIDIAN);
      CreateBackgroundPanelLower(DB_PREFIX+"scanline_bottom_"+IntegerToString(i), DB_X+2, DB_Y+3,    14, 2, C_CRIMSON,C_OBSIDIAN);
      CreateBackgroundPanelLower(DB_PREFIX+"scanline_left_"+IntegerToString(i),   DB_X+2, DB_Y+3,    2, 12, C_GOLDDIM,C_OBSIDIAN);
      CreateBackgroundPanelLower(DB_PREFIX+"scanline_right_"+IntegerToString(i),  DB_X+w-4, DB_Y+h-49,2, 12, C_GOLDDIM,C_OBSIDIAN);
   }

   CreateBackgroundPanelLower(DB_PREFIX+"border_glow_top",    DB_X+2,   DB_Y+h-3, w-4, 1, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"border_glow_bottom", DB_X+2,   DB_Y+2,   w-4, 1, C_GOLD, C_OBSIDIAN);
}

//===================================================================
//  MAIN SOVEREIGN DASHBOARD IV — precision-tuned layout grid,
//  magnified balance module, adapted to the recovery-grid engine.
//===================================================================
string StateToText(ENUM_EA_STATE st)
{
   switch(st)
   {
      case STATE_INIT:                return "INITIALIZING";
      case STATE_WAITING_FOR_TRIGGER: return "ARMED / WAITING";
      case STATE_BUY_BASKET_ACTIVE:   return "BUY-ACTIVE";
      case STATE_SELL_BASKET_ACTIVE:  return "SELL-ACTIVE";
      case STATE_CLOSING_BASKET:      return "CLOSING BASKET";
      case STATE_RESETTING_CYCLE:     return "RESETTING CYCLE";
      default:                        return "UNKNOWN";
   }
}

void BuildDashboard()
{
   int w = DashboardWidth;
   int h = DashboardHeight;

   CreateBackgroundPanelLower(DB_PREFIX+"bg_outer", DB_X, DB_Y, w, h, C_OBSIDIAN, C_GOLD);
   CreateBackgroundPanelLower(DB_PREFIX+"bg_inner", DB_X+2, DB_Y+2, w-4, h-4, C_ONYX, C_CRIMSON);

   // --- Header strip: main title + strap-line subtitle ---
   CreateBackgroundPanelLower(DB_PREFIX+"hdrstrip", DB_X+2, DB_Y+h-36, w-4, 34, C_CHARCOAL, C_OBSIDIAN);
   CreateLabelLower(DB_PREFIX+"hdr", ":::::::GOLD-PIP MINER EA V6", DB_X+14, DB_Y+h-20, FS_TITLE, C_GOLDBRIGHT, true);
   CreateLabelLower(DB_PREFIX+"hdrsub", "ROBUST DYNAMIC HYBRID ALGO", DB_X+14, DB_Y+h-35, FS_SUBTITLE, C_SLATE);
   CreateBackgroundPanelLower(DB_PREFIX+"hdrscan", DB_X+14, DB_Y+h-35, 36, 1, C_GOLDDIM, C_OBSIDIAN);

   CreateBackgroundPanelLower(DB_PREFIX+"livedot", DB_X+w-150, DB_Y+h-19, 9, 9, C_GREEN_OK, C_OBSIDIAN);
   CreateLabelLower(DB_PREFIX+"livetxt", "LIVE", DB_X+w-134, DB_Y+h-21, FS_LIVE, C_GREEN_OK, true);

   CreateCornerBrackets(w, h);

   int colTopY = DB_Y + h - 48;

   int c1x = DB_X + 16;           // STATE & FILTERS
   int c2x = c1x + 195;           // GRID & RISK
   int c3x = c2x + 195;           // GRID LADDER + VERTEX-IQ (stacked)
   int c4x = c3x + 195;           // ACCOUNT
   int c5x = c4x + 215;           // PERFORMANCE
   int c6x = c5x + 195;           // SESSION / MARKET / VOLATILITY / CONFIDENCE ARC

   // --- COLUMN 1 : STATE & FILTERS ---
   CreateLabelLower(DB_PREFIX+"sec_state", "STATE & FILTERS", c1x, colTopY, FS_SECTION, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"l_state", "State:",       c1x, colTopY-22, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_state", "",             c1x+100, colTopY-22, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_basket","Basket:",      c1x, colTopY-42, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_basket","",             c1x+100, colTopY-42, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_sess",  "Session:",     c1x, colTopY-62, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_sess",  "",             c1x+100, colTopY-62, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_news",  "News Filter:", c1x, colTopY-82, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_news",  "",             c1x+100, colTopY-82, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_guard", "Max DD Guard:",c1x, colTopY-102, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_guard", "",             c1x+100, colTopY-102, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_spr",   "Spread($):",   c1x, colTopY-122, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_spr",   "",             c1x+100, colTopY-122, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_arrows","Chart Arrows:",c1x, colTopY-142, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_arrows","",             c1x+100, colTopY-142, FS_VALUE, C_IVORY, true);

   // --- COLUMN 2 : GRID & RISK ---
   CreateLabelLower(DB_PREFIX+"sec_grid", "RISK STATISTICS", c2x, colTopY, FS_SECTION, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"l_ilot",  "Initial Lot:", c2x, colTopY-22, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_ilot",  "",             c2x+100, colTopY-22, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_mult",  "Lot Multiplier:",c2x, colTopY-42, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_mult",  DoubleToString(E1,2)+"x", c2x+100, colTopY-42, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_step",  "Grid Step 1/2:",c2x, colTopY-62, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_step",  DoubleToString(S1,2)+" / "+DoubleToString(S2,2), c2x+100, colTopY-62, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_maxb",  "Max Basket Size:",c2x, colTopY-82, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_maxb",  IntegerToString(N), c2x+100, colTopY-82, FS_VALUE, C_SLATE, true);
   CreateLabelLower(DB_PREFIX+"l_spmax", "Max Spread($):",c2x, colTopY-102, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_spmax", DoubleToString(P1,2), c2x+100, colTopY-102, FS_VALUE, C_SLATE, true);
   CreateLabelLower(DB_PREFIX+"l_tp",    "Basket TP/Lot:", c2x, colTopY-122, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_tp",    "$"+DoubleToString(T1,2), c2x+100, colTopY-122, FS_VALUE, C_IVORY, true);

   // --- COLUMN 3 : GRID LADDER (Vertex-IQ is embedded directly beneath it) ---
   CreateLabelLower(DB_PREFIX+"sec_ladder", "TRADE LADDER PROJECTOR", c3x, colTopY, FS_SECTION, C_GOLD, true);

   // --- COLUMN 4 : ACCOUNT — magnified balance module up top ---
   CreateLabelLower(DB_PREFIX+"sec_acct", "ACCOUNT STATISTICS", c4x, colTopY, FS_SECTION, C_GOLD, true);

   CreateBackgroundPanelLower(DB_PREFIX+"bal_shadow", c4x-2, colTopY-58, 200, 44, C_SHADOW, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"bal_box",     c4x-6, colTopY-56, 200, 44, C_CHARCOAL2, C_GOLD);
   CreateBackgroundPanelLower(DB_PREFIX+"bal_accent",  c4x-6, colTopY-14, 200, 2,  C_GOLDBRIGHT, C_OBSIDIAN);
   CreateLabelLower(DB_PREFIX+"l_bal_cap", ":::ACCOUNT BALANCE", c4x+4, colTopY-40, FS_BAL_CAP, C_GOLDDIM, true);
   CreateLabelLower(DB_PREFIX+"v_bal",     "",                c4x+4, colTopY-54, FS_BAL_VAL, C_GOLDBRIGHT, true);

   CreateLabelLower(DB_PREFIX+"l_eq",    "Account-Equity:",     c4x, colTopY-76, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_eq",    "",            c4x+100, colTopY-76, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_pl",    "Session P/L:",c4x, colTopY-99, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_pl",    "",            c4x+100, colTopY-99, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_openpl","Open P/L:",   c4x, colTopY-116, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_openpl","",            c4x+100, colTopY-116, FS_VALUE, C_IVORY, true);

   // --- COLUMN 5 : PERFORMANCE ---
   CreateLabelLower(DB_PREFIX+"sec_perf", "PERFORMANCE", c5x, colTopY, FS_SECTION, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"l_win",   "Win/Loss:",   c5x, colTopY-22, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_win",   "",            c5x+90, colTopY-22, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_total", "Total:",      c5x, colTopY-42, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_total", "",            c5x+90, colTopY-42, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_wr",    "Win Rate:",   c5x, colTopY-62, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_wr",    "",            c5x+90, colTopY-62, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_open",  "Open Trades:",c5x, colTopY-82, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_open",  "",            c5x+90, colTopY-82, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_status","System:",     c5x, colTopY-102, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_status","",            c5x+90, colTopY-102, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_pf",    "Profit Factor:",c5x, colTopY-122, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_pf",    "",            c5x+90, colTopY-122, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_peak",  "Peak Equity:",c5x, colTopY-142, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_peak",  "",            c5x+90, colTopY-142, FS_VALUE, C_IVORY, true);
   CreateLabelLower(DB_PREFIX+"l_fm",    "Free Margin:",c5x, colTopY-162, FS_LABEL, C_IVORY);
   CreateLabelLower(DB_PREFIX+"v_fm",    "",            c5x+90, colTopY-162, FS_VALUE, C_IVORY, true);

   // --- COLUMN 6 : SESSION / MARKET / VOLATILITY / CONFIDENCE ARC (header only) ---
   CreateLabelLower(DB_PREFIX+"sec_extra", "LIVE INTELLIGENCE", c6x, colTopY, FS_SECTION, C_GOLD, true);

   // --- Thin gold column dividers (7 zones total, including the data-rain strip) ---
   int dividerTopY = colTopY + 14;
   int dividerBotY = 170;
   int dividerH    = dividerTopY - dividerBotY;
   CreateBackgroundPanelLower(DB_PREFIX+"div1", c1x+195, dividerBotY, 1, dividerH, C_STEEL, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"div2", c2x+195, dividerBotY, 1, dividerH, C_STEEL, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"div3", c3x+195, dividerBotY, 1, dividerH, C_STEEL, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"div4", c4x+215, dividerBotY, 1, dividerH, C_STEEL, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"div5", c5x+195, dividerBotY, 1, dividerH, C_STEEL, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"div6", c6x+195, dividerBotY, 1, dividerH, C_STEEL, C_OBSIDIAN);

   // --- PRESSURE GAUGE ROW ---
   int gY = 90;
   CreateLabelLower(DB_PREFIX+"l_gauge", "Bull/Bear Pressure:", c1x, gY, FS_LABEL, C_IVORY);
   CreateBackgroundPanelLower(DB_PREFIX+"gauge_bg",   c1x+150, gY-2, 240, 10, C_CHARCOAL2, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"gauge_bull",  c1x+150, gY-2, 120, 10, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"gauge_bear",  c1x+270, gY-2, 120, 10, C_CRIMSON, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"gauge_marker", c1x+150+119, gY-4, 2, 14, C_GOLDBRIGHT, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"gauge_tick25", c1x+150+60,  gY-3, 1, 12, C_STEEL, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"gauge_tick75", c1x+150+180, gY-3, 1, 12, C_STEEL, C_OBSIDIAN);

   // --- STATUS STRIP (GUARD / STREAK / MAGIC / DD% / HEARTBEAT) ---
   int lY = 64;
   CreateBackgroundPanelLower(DB_PREFIX+"lic_strip", DB_X+4, lY-8, w-8, 24, C_CHARCOAL, C_OBSIDIAN);

   CreateLabelLower(DB_PREFIX+"l_grd2",  "GUARD:",      c1x, lY, FS_STRIP, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"v_grd2",  "",            c1x+72, lY, FS_STRIP, C_IVORY, true);

   CreateLabelLower(DB_PREFIX+"l_streak","STREAK:",     c2x, lY, FS_STRIP, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"v_streak","",            c2x+72, lY, FS_STRIP, C_IVORY, true);

   CreateLabelLower(DB_PREFIX+"l_magic", "MAGIC:",      c3x, lY, FS_STRIP, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"v_magic", IntegerToString((int)M1)+" / "+IntegerToString((int)M2), c3x+72, lY, FS_STRIP, C_IVORY, true);

   CreateLabelLower(DB_PREFIX+"l_ddpct", "DD%:",        c4x, lY, FS_STRIP, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"v_ddpct", "",            c4x+50, lY, FS_STRIP, C_IVORY, true);

   CreateLabelLower(DB_PREFIX+"l_hb",    "OPTIX:",  c5x, lY, FS_STRIP, C_GOLD, true);
   CreateBackgroundPanelLower(DB_PREFIX+"hb_dot", c5x+82, lY+1, 6, 6, C_GOLD, C_OBSIDIAN);

   CreateLabelLower(DB_PREFIX+"l_conf2", "CONF:",       c6x, lY, FS_STRIP, C_GOLD, true);
   CreateLabelLower(DB_PREFIX+"v_conf2", "",            c6x+50, lY, FS_STRIP, C_IVORY, true);

   // --- Copyright footer (bottom-left corner, inside panel) ---
   CreateLabelLower(DB_PREFIX+"copyright", "(c) 2026 ExpertFXHub  ::  Sovereign Dashboard IV", DB_X+w-260, DB_Y+6, FS_FOOTER, C_STEEL);

   ChartRedraw();
}

//===================================================================
//  ORBITAL SPINNER IV — tri-ring hybrid core.
//===================================================================
void BuildSpinner()
{
   int w = DashboardWidth, h = DashboardHeight;
   g_spin_cx = DB_X + w - 190;
   g_spin_cy = DB_Y + h - 15;

   for(int i = 0; i < SPIN_DOTS; i++)
   {
      double ang = (2.0 * M_PI * i) / SPIN_DOTS;
      g_spin_x[i] = g_spin_cx + (int)MathRound(MathCos(ang) * g_spin_radius);
      g_spin_y[i] = g_spin_cy + (int)MathRound(MathSin(ang) * g_spin_radius);
      CreateBackgroundPanelLower(DB_PREFIX+"spin_"+IntegerToString(i), g_spin_x[i], g_spin_y[i], 3, 3, C_STEEL, C_OBSIDIAN);
   }

   for(int i = 0; i < SPIN_DOTS_OUTER; i++)
   {
      double ang = (2.0 * M_PI * i) / SPIN_DOTS_OUTER;
      g_spin_ox[i] = g_spin_cx + (int)MathRound(MathCos(ang) * g_spin_radius_outer);
      g_spin_oy[i] = g_spin_cy + (int)MathRound(MathSin(ang) * g_spin_radius_outer);
      CreateBackgroundPanelLower(DB_PREFIX+"spinO_"+IntegerToString(i), g_spin_ox[i], g_spin_oy[i], 2, 2, C_STEEL, C_OBSIDIAN);
   }

   for(int i = 0; i < SPIN_DOTS_HALO; i++)
   {
      double ang = (2.0 * M_PI * i) / SPIN_DOTS_HALO;
      g_spin_hx[i] = g_spin_cx + (int)MathRound(MathCos(ang) * g_spin_radius_halo);
      g_spin_hy[i] = g_spin_cy + (int)MathRound(MathSin(ang) * g_spin_radius_halo);
      CreateBackgroundPanelLower(DB_PREFIX+"spinH_"+IntegerToString(i), g_spin_hx[i], g_spin_hy[i], 2, 2, C_STEEL, C_OBSIDIAN);
   }
}

void UpdateSpinner()
{
   int speed = MathMax(1, AnimationSpeed);

   g_spin_index = (g_spin_index + speed) % SPIN_DOTS;
   for(int i = 0; i < SPIN_DOTS; i++)
   {
      int dist = MathAbs(i - g_spin_index);
      if(dist > SPIN_DOTS/2) dist = SPIN_DOTS - dist;
      double t = MathMin(1.0, dist / 3.0);
      color clr = BlendColor(C_GOLDBRIGHT, C_STEEL, t);
      UpdRect(DB_PREFIX+"spin_"+IntegerToString(i), clr);
   }

   g_spin_outer_index = (g_spin_outer_index - speed + SPIN_DOTS_OUTER) % SPIN_DOTS_OUTER;
   for(int i = 0; i < SPIN_DOTS_OUTER; i++)
   {
      int dist = MathAbs(i - g_spin_outer_index);
      if(dist > SPIN_DOTS_OUTER/2) dist = SPIN_DOTS_OUTER - dist;
      double t = MathMin(1.0, dist / 4.0);
      color clr = BlendColor(C_CRIMSON, C_STEEL, t);
      UpdRect(DB_PREFIX+"spinO_"+IntegerToString(i), clr);
   }

   g_spin_halo_index = (g_spin_halo_index + MathMax(1, speed)) % SPIN_DOTS_HALO;
   for(int i = 0; i < SPIN_DOTS_HALO; i++)
   {
      int dist = MathAbs(i - g_spin_halo_index);
      if(dist > SPIN_DOTS_HALO/2) dist = SPIN_DOTS_HALO - dist;
      double t = MathMin(1.0, dist / 5.0);
      color clr = BlendColor(C_AZURE, C_STEEL, t);
      UpdRect(DB_PREFIX+"spinH_"+IntegerToString(i), clr);
   }
}

//===================================================================
//  AI CORE — rotating hex accent with a breathing center dot.
//===================================================================
void BuildHexCore()
{
   int w = DashboardWidth, h = DashboardHeight;
   g_hex_cx = DB_X + w - 240;
   g_hex_cy = DB_Y + h - 15;

   for(int i = 0; i < HEX_DOTS; i++)
   {
      double ang = (2.0 * M_PI * i) / HEX_DOTS;
      g_hex_x[i] = g_hex_cx + (int)MathRound(MathCos(ang) * g_hex_radius);
      g_hex_y[i] = g_hex_cy + (int)MathRound(MathSin(ang) * g_hex_radius);
      CreateBackgroundPanelLower(DB_PREFIX+"hex_"+IntegerToString(i), g_hex_x[i], g_hex_y[i], 3, 3, C_VIOLET, C_OBSIDIAN);
   }
   CreateBackgroundPanelLower(DB_PREFIX+"hex_core", g_hex_cx-1, g_hex_cy-1, 3, 3, C_GOLDBRIGHT, C_OBSIDIAN);
   CreateLabelLower(DB_PREFIX+"hex_lbl", "AI CORE", g_hex_cx-38, g_hex_cy-4, FS_FOOTER, C_SLATE, true);
}

void UpdateHexCore()
{
   g_hex_index = (g_hex_index + 1) % HEX_DOTS;
   for(int i = 0; i < HEX_DOTS; i++)
   {
      color clr = C_STEEL;
      if(i == g_hex_index)
      {
         clr = C_GOLDBRIGHT;
      }
      else
      {
         int dist = MathAbs(i - g_hex_index);
         if(dist > HEX_DOTS/2) dist = HEX_DOTS - dist;
         if(dist == 1) clr = BlendColor(C_STEEL, C_VIOLET, 0.45);
      }
      UpdRect(DB_PREFIX+"hex_"+IntegerToString(i), clr);
   }

   g_hex_pulse += 0.22 * MathMax(1, AnimationSpeed);
   double glow = BreathWave(g_hex_pulse);
   UpdRect(DB_PREFIX+"hex_core", BlendColor(C_VIOLET, C_GOLDBRIGHT, glow));
}

//===================================================================
//  HEADER CIRCUIT-SCAN
//===================================================================
void AnimateHeaderScan()
{
   int trackW = 170;
   g_hdrscan_pos += g_hdrscan_dir * MathMax(1, AnimationSpeed) * 3;
   if(g_hdrscan_pos >= trackW) { g_hdrscan_pos = trackW; g_hdrscan_dir = -1; }
   if(g_hdrscan_pos <= 0)      { g_hdrscan_pos = 0;      g_hdrscan_dir = 1;  }

   ObjectSetInteger(0, DB_PREFIX+"hdrscan", OBJPROP_XDISTANCE, DB_X+14+g_hdrscan_pos);
   double t = BreathWave(AnimationTick*0.25);
   UpdRect(DB_PREFIX+"hdrscan", BlendColor(C_GOLD, C_CRIMSON, t));
}

//===================================================================
//  LIVE EQUITY SPARKLINE
//===================================================================
void BuildSparkline()
{
   int w = DashboardWidth;
   int sparkTopY = 150;

   CreateLabelLower(DB_PREFIX+"spark_hdr", "LIVE EQUITY CURVE", DB_X+16, sparkTopY+4, FS_SPARKHDR, C_GOLDDIM, true);
   CreateLabelLower(DB_PREFIX+"spark_hi",  "", DB_X+16+150, sparkTopY+4, FS_SPARKHDR, C_GREEN_OK, true);
   CreateLabelLower(DB_PREFIX+"spark_lo",  "", DB_X+16+260, sparkTopY+4, FS_SPARKHDR, C_RED_BAD, true);
   CreateBackgroundPanelLower(DB_PREFIX+"spark_bg", DB_X+16, sparkTopY-g_spark_max_h-2, w-32, g_spark_max_h+2, C_CHARCOAL, C_OBSIDIAN);

   g_spark_x      = DB_X + 22;
   g_spark_base_y = sparkTopY - g_spark_max_h - 1;

   for(int i = 0; i < SPARK_COUNT; i++)
   {
      int bx = g_spark_x + i * (g_spark_bar_w + g_spark_bar_gap);
      CreateBackgroundPanelLower(DB_PREFIX+"spark_"+IntegerToString(i), bx, g_spark_base_y, g_spark_bar_w, 1, C_GOLDDIM, C_OBSIDIAN);
   }
}

void SampleEquitySpark()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(g_spark_filled < SPARK_COUNT)
   {
      g_spark_values[g_spark_filled] = eq;
      g_spark_filled++;
   }
   else
   {
      for(int i = 0; i < SPARK_COUNT - 1; i++)
         g_spark_values[i] = g_spark_values[i+1];
      g_spark_values[SPARK_COUNT-1] = eq;
   }
}

void UpdateSparkline()
{
   g_spark_tick++;
   int sampleEvery = MathMax(3, 15 / MathMax(1, AnimationSpeed));
   if(g_spark_tick % sampleEvery == 0)
      SampleEquitySpark();

   if(g_spark_filled == 0) return;

   double lo = g_spark_values[0], hi = g_spark_values[0];
   int hiIdx = 0, loIdx = 0;
   for(int i = 1; i < g_spark_filled; i++)
   {
      if(g_spark_values[i] < lo) { lo = g_spark_values[i]; loIdx = i; }
      if(g_spark_values[i] > hi) { hi = g_spark_values[i]; hiIdx = i; }
   }
   double range = hi - lo;
   if(range < 1.0) range = 1.0;

   UpdLbl(DB_PREFIX+"spark_hi", "HIGH: $"+DoubleToString(hi,2), C_GREEN_OK);
   UpdLbl(DB_PREFIX+"spark_lo", "LOW: $"+DoubleToString(lo,2), C_RED_BAD);

   for(int i = 0; i < SPARK_COUNT; i++)
   {
      string nm = DB_PREFIX+"spark_"+IntegerToString(i);
      if(i >= g_spark_filled)
      {
         ObjectSetInteger(0, nm, OBJPROP_YSIZE, 1);
         UpdRect(nm, C_STEEL);
         continue;
      }
      double v = g_spark_values[i];
      double frac = (v - lo) / range;
      int barH = (int)MathMax(1.0, frac * g_spark_max_h);
      ObjectSetInteger(0, nm, OBJPROP_YSIZE, barH);

      color barClr = BlendColor(C_DEEPCRIMSON, C_GOLDBRIGHT, frac);

      if(i > 0)
      {
         double prev = g_spark_values[i-1];
         if(v < prev) barClr = BlendColor(barClr, C_RED_BAD, 0.35);
         else if(v > prev) barClr = BlendColor(barClr, C_GREEN_OK, 0.25);
      }

      if(i == g_spark_filled - 1)
      {
         double glow = BreathWave(AnimationTick * 0.35);
         barClr = BlendColor(C_GOLD, C_GOLDBRIGHT, glow);
      }
      UpdRect(nm, barClr);
   }
}

//===================================================================
//  GRID LADDER PROJECTOR
//===================================================================
void GetBasketLastLotAndCount(ENUM_POSITION_TYPE type, double &lastLot, int &count)
{
   lastLot = 0.0;
   count   = 0;
   datetime latest_time = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && IsOurMagic(m_position.Magic()) &&
            m_position.PositionType() == type)
         {
            count++;
            datetime pos_time = m_position.Time();
            if(pos_time >= latest_time)
            {
               latest_time = pos_time;
               lastLot = m_position.Volume();
            }
         }
      }
   }
}

void BuildGridLadder()
{
   int colTopY = DB_Y + DashboardHeight - 48;
   int c3x = DB_X + 16 + 195 + 195;

   for(int n = 1; n <= LADDER_LEVELS; n++)
   {
      int y = colTopY - (n*22);
      CreateBackgroundPanelLower(DB_PREFIX+"lv_bg"+IntegerToString(n), c3x-4, y-4, 180, 18, C_CHARCOAL, C_OBSIDIAN);
      CreateLabelLower(DB_PREFIX+"l_lv"+IntegerToString(n), "Lv "+IntegerToString(n)+":", c3x, y, FS_LADDER, C_IVORY);
      CreateLabelLower(DB_PREFIX+"v_lv"+IntegerToString(n), "",  c3x+38, y, FS_LADDER, C_IVORY, true);
   }
}

void UpdateGridLadder()
{
   int buyCt  = GetPositionCount(POSITION_TYPE_BUY);
   int sellCt = GetPositionCount(POSITION_TYPE_SELL);

   ENUM_POSITION_TYPE dir = POSITION_TYPE_BUY;
   bool haveBasket = false;
   if(buyCt > 0)       { dir = POSITION_TYPE_BUY;  haveBasket = true; }
   else if(sellCt > 0) { dir = POSITION_TYPE_SELL; haveBasket = true; }

   double lastLot; int count;
   if(haveBasket)
      GetBasketLastLotAndCount(dir, lastLot, count);
   else
   {
      lastLot = GetConfiguredInitialLot();
      count   = 0;
   }

   color tiers[4] = {VTX_T4, VTX_T6, VTX_T8, VTX_T10};

   g_ladder_pulse += 0.28 * MathMax(1, AnimationSpeed);

   for(int n = 1; n <= LADDER_LEVELS; n++)
   {
      double dist = GetGridDistancePrice(count + n - 1);
      double lot  = NormalizeVolume(lastLot * MathPow(E1, n));
      if(lot > InpMaxLot) lot = InpMaxLot;

      string txt = "-$"+DoubleToString(dist,2)+"  |  "+DoubleToString(lot,2)+"L";
      color baseClr = tiers[n-1];

      if(n == 1 && haveBasket)
      {
         double glow = BreathWave(g_ladder_pulse);
         UpdRect(DB_PREFIX+"lv_bg1", BlendColor(C_CHARCOAL, C_DEEPCRIMSON, glow*0.6));
         baseClr = BlendColor(baseClr, C_GOLDBRIGHT, glow);
      }
      else
      {
         UpdRect(DB_PREFIX+"lv_bg"+IntegerToString(n), C_CHARCOAL);
      }

      UpdLbl(DB_PREFIX+"v_lv"+IntegerToString(n), txt, baseClr);
   }
}

//===================================================================
//  RISK THERMOMETER
//===================================================================
void BuildRiskMeter()
{
   int w = DashboardWidth;
   g_risk_x       = DB_X + w - 34;
   g_risk_base_y  = 225;

   CreateLabelLower(DB_PREFIX+"risk_hdr", "DD", g_risk_x-2, g_risk_base_y + RISK_SEGS*(g_risk_seg_h+g_risk_seg_gap) + 6, FS_RISKHDR, C_GOLDDIM, true);
   CreateLabelLower(DB_PREFIX+"risk_val", "0.0%", g_risk_x-8, g_risk_base_y - 16, FS_RISKVAL, C_IVORY, true);

   for(int i = 0; i < RISK_SEGS; i++)
   {
      int y = g_risk_base_y + i*(g_risk_seg_h+g_risk_seg_gap);
      CreateBackgroundPanelLower(DB_PREFIX+"risk_seg_"+IntegerToString(i), g_risk_x, y, 22, g_risk_seg_h, C_CHARCOAL2, C_STEEL);
   }
}

void UpdateRiskMeter()
{
   double ddNow = GetCurrentDrawdownPercent();
   double smooth_factor = MathMin(0.4, 0.15 * MathMax(1, AnimationSpeed));
   g_risk_smoothed += (ddNow - g_risk_smoothed) * smooth_factor;

   double ceiling = (InpMaxDrawdownPercent > 0.0) ? InpMaxDrawdownPercent : 20.0;
   double fraction = MathMin(1.0, g_risk_smoothed / ceiling);
   double exact_segs = fraction * RISK_SEGS;
   int litSegs = (int)MathFloor(exact_segs);
   double boundaryFrac = exact_segs - litSegs;

   color tierColors[10] = {VTX_T1, VTX_T2, VTX_T3, VTX_T4, VTX_T5, VTX_T6, VTX_T7, VTX_T8, VTX_T9, VTX_T10};
   bool dangerZone = (fraction > 0.85);
   bool blinkOn = ((AnimationTick / 5) % 2) == 0;

   for(int i = 0; i < RISK_SEGS; i++)
   {
      string nm = DB_PREFIX+"risk_seg_"+IntegerToString(i);
      if(i < litSegs)
      {
         if(i == RISK_SEGS-1 && dangerZone && !blinkOn)
            UpdRect(nm, C_CHARCOAL2);
         else
            UpdRect(nm, tierColors[i]);
      }
      else if(i == litSegs && boundaryFrac > 0.02)
      {
         UpdRect(nm, BlendColor(C_CHARCOAL2, tierColors[MathMin(i,9)], boundaryFrac));
      }
      else
      {
         UpdRect(nm, C_CHARCOAL2);
      }
   }

   color valClr = (fraction > 0.75) ? C_RED_BAD : (fraction > 0.4) ? C_EMBER : C_IVORY;
   UpdLbl(DB_PREFIX+"risk_val", DoubleToString(g_risk_smoothed,1)+"%", valClr);
}

//===================================================================
//  VOLATILITY GAUGE
//===================================================================
void BuildVolatilityGauge()
{
   int w = DashboardWidth;
   int c6x = DB_X + 16 + 195*5;
   int colTopY = DB_Y + DashboardHeight - 48;

   g_vol_x       = c6x;
   g_vol_base_y  = colTopY - 200;

   CreateLabelLower(DB_PREFIX+"vol_hdr", "VOLATILITY (ATR H1)", c6x, colTopY-92, FS_VOL_HDR, C_GOLDDIM, true);
   CreateLabelLower(DB_PREFIX+"vol_val", "", c6x+150, colTopY-92, FS_VOL_VAL, C_IVORY, true);
   CreateBackgroundPanelLower(DB_PREFIX+"vol_bg", c6x, colTopY-108, 190, 10, C_CHARCOAL2, C_OBSIDIAN);
   for(int i = 0; i < VOL_SEGS; i++)
   {
      int sx = c6x + i*19;
      CreateBackgroundPanelLower(DB_PREFIX+"vol_seg_"+IntegerToString(i), sx, colTopY-108, 16, 10, C_CHARCOAL2, C_STEEL);
   }
}

void UpdateVolatilityGauge()
{
   if(g_atr_handle == INVALID_HANDLE) return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atrBuf) <= 0) return;

   double atr = atrBuf[0];

   if(g_vol_baseline_count < 200)
   {
      g_vol_baseline = (g_vol_baseline * g_vol_baseline_count + atr) / (g_vol_baseline_count + 1);
      g_vol_baseline_count++;
   }
   else
   {
      g_vol_baseline += (atr - g_vol_baseline) * 0.01;
   }
   if(g_vol_baseline <= 0.0) g_vol_baseline = atr > 0 ? atr : 1.0;

   double ratio = atr / g_vol_baseline;
   double fraction = MathMin(1.0, MathMax(0.0, (ratio - 0.4) / 2.2));
   g_vol_smoothed += (fraction - g_vol_smoothed) * 0.12;

   int litSegs = (int)MathRound(g_vol_smoothed * VOL_SEGS);
   color tierColors[10] = {VOL_T1, VOL_T2, VOL_T3, VOL_T4, VOL_T5, VOL_T6, VOL_T7, VOL_T8, VOL_T9, VOL_T10};

   for(int i = 0; i < VOL_SEGS; i++)
   {
      string nm = DB_PREFIX+"vol_seg_"+IntegerToString(i);
      UpdRect(nm, (i < litSegs) ? tierColors[i] : C_CHARCOAL2);
   }

   color valClr = (ratio > 2.0) ? C_RED_BAD : (ratio > 1.4) ? C_VIOLET : C_AZURE;
   UpdLbl(DB_PREFIX+"vol_val", DoubleToString(atr,2)+" ("+DoubleToString(ratio,2)+"x)", valClr);
}

//===================================================================
//  SESSION CLOCK
//===================================================================
void BuildSessionClock()
{
   int c6x = DB_X + 16 + 195*5;
   int colTopY = DB_Y + DashboardHeight - 48;

   CreateLabelLower(DB_PREFIX+"clk_hdr",  "BROKER SESSION CLOCK", c6x, colTopY-22, FS_PULSE_HDR, C_GOLDDIM, true);
   CreateBackgroundPanelLower(DB_PREFIX+"clk_ring", c6x, colTopY-44, 10, 10, C_GREEN_OK, C_OBSIDIAN);
   CreateLabelLower(DB_PREFIX+"clk_time", "00:00:00", c6x+16, colTopY-48, FS_CLOCK_TIME, C_GOLDBRIGHT, true);
   CreateLabelLower(DB_PREFIX+"clk_date", "---, ---- --", c6x+16, colTopY-67, FS_CLOCK_DATE, C_SLATE);
}

void UpdateSessionClock()
{
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   MqlDateTime tm;
   TimeToStruct(now, tm);

   string colon = ((AnimationTick % 10) < 5) ? ":" : " ";
   string timeStr = StringFormat("%02d%s%02d%s%02d", tm.hour, colon, tm.min, colon, tm.sec);
   UpdLbl(DB_PREFIX+"clk_time", timeStr, C_GOLDBRIGHT);

   string dow = (tm.day_of_week >= 0 && tm.day_of_week <= 6) ? g_dow_names[tm.day_of_week] : "---";
   string dateStr = StringFormat("%s, %04d-%02d-%02d", dow, tm.year, tm.mon, tm.day);
   UpdLbl(DB_PREFIX+"clk_date", dateStr, C_SLATE);

   bool sessOpen = IsTradingSessionOpen();
   double pulse = BreathWave(AnimationTick * 0.3);
   color ringClr = sessOpen ? BlendColor(C_GREEN_OK, C_GOLDBRIGHT, pulse*0.4) : BlendColor(C_STEEL, C_RED_BAD, 0.5);
   UpdRect(DB_PREFIX+"clk_ring", ringClr);
}

//===================================================================
//  MARKET PULSE
//===================================================================
void BuildMarketPulse()
{
   int c6x = DB_X + 16 + 195*5;
   int colTopY = DB_Y + DashboardHeight - 48;
   int baseY = colTopY - 130;

   CreateLabelLower(DB_PREFIX+"pulse_hdr", "MARKET PULSE (H1 x"+IntegerToString(PULSE_COUNT)+")", c6x, baseY+22, FS_PULSE_HDR, C_GOLDDIM, true);
   CreateBackgroundPanelLower(DB_PREFIX+"pulse_bg", c6x, baseY-2, 190, 20, C_CHARCOAL, C_OBSIDIAN);

   for(int i = 0; i < PULSE_COUNT; i++)
   {
      int bx = c6x + 4 + i*13;
      CreateBackgroundPanelLower(DB_PREFIX+"pulse_"+IntegerToString(i), bx, baseY, 10, 4, C_STEEL, C_OBSIDIAN);
   }
}

void UpdateMarketPulse()
{
   for(int i = 0; i < PULSE_COUNT; i++)
   {
      int shiftBack = PULSE_COUNT - i;
      double o = iOpen(_Symbol, PERIOD_H1, shiftBack);
      double c = iClose(_Symbol, PERIOD_H1, shiftBack);
      bool up = (c >= o);

      color base = up ? C_GOLD : C_CRIMSON;
      int h = up ? (int)MathMin(16, MathMax(4, 4 + MathAbs(c-o)*40)) : (int)MathMin(16, MathMax(4, 4 + MathAbs(c-o)*40));

      string nm = DB_PREFIX+"pulse_"+IntegerToString(i);
      ObjectSetInteger(0, nm, OBJPROP_YSIZE, h);

      if(i == PULSE_COUNT - 1)
      {
         double glow = BreathWave(AnimationTick * 0.4);
         base = BlendColor(base, C_GOLDBRIGHT, up ? glow : 0.0);
         if(!up) base = BlendColor(base, C_EMBER, glow*0.5);
      }
      UpdRect(nm, base);
   }
}

//===================================================================
//  ROTATING STATUS TICKER
//===================================================================
void BuildTicker()
{
   int w = DashboardWidth;
   CreateBackgroundPanelLower(DB_PREFIX+"ticker_bg", DB_X+4, 28, w-8, 18, C_CHARCOAL2, C_OBSIDIAN);
   CreateBackgroundPanelLower(DB_PREFIX+"ticker_dot", DB_X+12, 34, 6, 6, C_GOLD, C_OBSIDIAN);
   CreateLabelLower(DB_PREFIX+"ticker_txt", "SYSTEM READY", DB_X+26, 32, FS_TICKER, C_IVORY, true);
}

void RebuildTickerMessages()
{
   int buyCt  = GetPositionCount(POSITION_TYPE_BUY);
   int sellCt = GetPositionCount(POSITION_TYPE_SELL);
   string basketStr = (buyCt>0) ? "BUY  ACTIVE ("+IntegerToString(buyCt)+" pos)" :
                       (sellCt>0) ? "SELL  ACTIVE ("+IntegerToString(sellCt)+" pos)" : "NO ACTIVE BASKET";

   g_ticker_msgs[0] = "STATE: " + StateToText(g_state);
   g_ticker_msgs[1] = "BASKET: " + basketStr;
   g_ticker_msgs[2] = F4 ? ("NEWS: " + (g_news_blocked ? ("BLOCKED — " + g_active_news_name) : "CLEAR — " + g_next_news_name)) : "NEWS FILTER: OFF";
   g_ticker_msgs[3] = "GUARD: " + (g_max_dd_emergency_active ? "EMERGENCY LIQUIDATION" :
                                    g_trading_stopped_by_max_dd ? "TRADING STOPPED (MAX DD)" :
                                    InpEnableMaxDDProtection ? "ARMED @ "+DoubleToString(InpMaxDrawdownPercent,1)+"%" : "OFF");
   g_ticker_msgs[4] = "EQUITY: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2) +
                       "  |  DD: " + DoubleToString(GetCurrentDrawdownPercent(),1) + "%";
}

void UpdateTicker()
{
   g_ticker_hold_ticks++;
   if(g_ticker_hold_ticks == 1)
      RebuildTickerMessages();

   int holdLength = MathMax(15, 40 / MathMax(1, AnimationSpeed));
   int fadeLength = 8;

   if(g_ticker_hold_ticks >= holdLength && !g_ticker_fading)
   {
      g_ticker_fading   = true;
      g_ticker_fade_ticks = 0;
   }

   color txtClr = C_IVORY;
   if(g_ticker_fading)
   {
      g_ticker_fade_ticks++;
      double t = (double)g_ticker_fade_ticks / fadeLength;
      if(t < 0.5)
      {
         txtClr = BlendColor(C_IVORY, C_STEEL, t*2.0);
      }
      else
      {
         if(g_ticker_fade_ticks == (int)MathCeil(fadeLength*0.5))
         {
            g_ticker_index = (g_ticker_index + 1) % TICKER_SLOTS;
            RebuildTickerMessages();
         }
         txtClr = BlendColor(C_STEEL, C_IVORY, (t-0.5)*2.0);
      }

      if(g_ticker_fade_ticks >= fadeLength)
      {
         g_ticker_fading      = false;
         g_ticker_hold_ticks  = 0;
      }
   }

   UpdLbl(DB_PREFIX+"ticker_txt", g_ticker_msgs[g_ticker_index], txtClr);

   bool dotOn = (AnimationTick % 10) < 6;
   UpdRect(DB_PREFIX+"ticker_dot", dotOn ? (color)C_GOLDBRIGHT : (color)C_GOLDDIM);
}

//===================================================================
//  QUAD-EDGE TRAILING CHASE LIGHTS
//===================================================================
void UpdateChaseEdges()
{
   int w = DashboardWidth, h = DashboardHeight;
   int speed = MathMax(1, AnimationSpeed);

   int innerWidthTop = w - 4 - 52;
   ScanLineTick += 6*speed;
   if(ScanLineTick > innerWidthTop) ScanLineTick = 0;
   int phaseTop = (ScanLineTick / 40) % 2;
   color headClrTop = (phaseTop==0) ? C_GOLD : C_CRIMSON;
   for(int i = 0; i < CHASE_TRAIL; i++)
   {
      int pos = ScanLineTick - i*10;
      if(pos < 0) pos += innerWidthTop;
      string nm = DB_PREFIX+"scanline_"+IntegerToString(i);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, DB_X + 2 + pos);
      double fade = 1.0 - (double)i / CHASE_TRAIL;
      UpdRect(nm, BlendColor(C_OBSIDIAN, headClrTop, fade));
   }

   ScanLineTickBottom -= 5*speed;
   if(ScanLineTickBottom < 0) ScanLineTickBottom = innerWidthTop;
   int phaseBot = (ScanLineTickBottom / 40) % 2;
   color headClrBot = (phaseBot==0) ? C_CRIMSON : C_GOLD;
   for(int i = 0; i < CHASE_TRAIL; i++)
   {
      int pos = ScanLineTickBottom + i*10;
      if(pos > innerWidthTop) pos -= innerWidthTop;
      string nm = DB_PREFIX+"scanline_bottom_"+IntegerToString(i);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, DB_X + 2 + pos);
      double fade = 1.0 - (double)i / CHASE_TRAIL;
      UpdRect(nm, BlendColor(C_OBSIDIAN, headClrBot, fade));
   }

   int innerHeight = h - 49 - 3;
   ScanLineTickLeft += 4*speed;
   if(ScanLineTickLeft > innerHeight) ScanLineTickLeft = 0;
   color edgeClrL = ((AnimationTick/10) % 2 == 0) ? C_GOLDDIM : C_BRASS;
   for(int i = 0; i < CHASE_TRAIL; i++)
   {
      int pos = ScanLineTickLeft - i*8;
      if(pos < 0) pos += innerHeight;
      string nm = DB_PREFIX+"scanline_left_"+IntegerToString(i);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, DB_Y + 3 + pos);
      double fade = 1.0 - (double)i / CHASE_TRAIL;
      UpdRect(nm, BlendColor(C_OBSIDIAN, edgeClrL, fade));
   }

   ScanLineTickRight -= 4*speed;
   if(ScanLineTickRight < 0) ScanLineTickRight = innerHeight;
   color edgeClrR = ((AnimationTick/10) % 2 == 0) ? C_BRASS : C_GOLDDIM;
   for(int i = 0; i < CHASE_TRAIL; i++)
   {
      int pos = ScanLineTickRight + i*8;
      if(pos > innerHeight) pos -= innerHeight;
      string nm = DB_PREFIX+"scanline_right_"+IntegerToString(i);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, DB_Y + 3 + pos);
      double fade = 1.0 - (double)i / CHASE_TRAIL;
      UpdRect(nm, BlendColor(C_OBSIDIAN, edgeClrR, fade));
   }
}

//===================================================================
//  BREATHING CORNER GLOW + OUTER BORDER PULSE
//===================================================================
void AnimateCornerGlow()
{
   g_corner_glow_phase += 0.12 * MathMax(1, AnimationSpeed);
   double t = BreathWave(g_corner_glow_phase);

   color glowClr = BlendColor(C_GOLDDIM, C_GOLDBRIGHT, t);
   UpdRect(DB_PREFIX+"glow_bl", glowClr);
   UpdRect(DB_PREFIX+"glow_br", glowClr);
   UpdRect(DB_PREFIX+"glow_tl", glowClr);
   UpdRect(DB_PREFIX+"glow_tr", glowClr);

   color borderClr = BlendColor(C_GOLD, C_GOLDBRIGHT, t*0.5);
   UpdRect(DB_PREFIX+"border_glow_top", borderClr);
   UpdRect(DB_PREFIX+"border_glow_bottom", borderClr);
}

//===================================================================
//  CONFIDENCE ARC — a 12-segment composite gauge blending trend
//  alignment (bull/bear pressure spread), RSI displacement from the
//  neutral 50 line, the current volatility regime, and session/news
//  gating into a single 0-100% "conviction" readout. Crimson (low)
//  through gold to neon-mint (high), with a bright leading edge.
//===================================================================
void BuildConfidenceArc()
{
   int c6x = DB_X + 16 + 195*5;
   int colTopY = DB_Y + DashboardHeight - 48;
   int y = colTopY - 190;

   CreateLabelLower(DB_PREFIX+"conf_hdr", "CONFIDENCE ARC", c6x, y+14, FS_CONF_HDR, C_GOLDDIM, true);
   CreateLabelLower(DB_PREFIX+"conf_val", "", c6x+150, y+15, FS_CONF_VAL, C_IVORY, true);
   CreateBackgroundPanelLower(DB_PREFIX+"conf_bg", c6x, y, 190, 10, C_CHARCOAL2, C_OBSIDIAN);
   for(int i = 0; i < CONF_SEGS; i++)
   {
      int sx = c6x + i*16;
      CreateBackgroundPanelLower(DB_PREFIX+"conf_seg_"+IntegerToString(i), sx, y, 13, 10, C_CHARCOAL2, C_STEEL);
   }
   g_conf_x = c6x;
   g_conf_y = y;
}

double ComputeConfidenceScore()
{
   // Factor 1: trend alignment - how one-sided bull/bear pressure is (0..1)
   double totalPressure = BullPressure + BearPressure;
   double trendFactor = (totalPressure > 0.0001) ? MathAbs(BullPressure - BearPressure) / totalPressure : 0.0;

   // Factor 2: RSI displacement from neutral (50) - stronger displacement = stronger conviction
   double rsiFactor = 0.5;
   if(g_rsi_handle != INVALID_HANDLE)
   {
      double rsiBuf[];
      ArraySetAsSeries(rsiBuf, true);
      if(CopyBuffer(g_rsi_handle, 0, 1, 1, rsiBuf) > 0)
         rsiFactor = MathMin(1.0, MathAbs(rsiBuf[0] - 50.0) / 35.0);
   }

   // Factor 3: volatility regime - moderate volatility scores higher than dead-flat or extreme
   double volFactor = 1.0 - MathAbs(g_vol_smoothed - 0.35) / 0.65;
   volFactor = MathMax(0.0, MathMin(1.0, volFactor));

   // Factor 4: session/news gate - fully open conditions add conviction, blocked conditions remove it
   double gateFactor = (IsTradingSessionOpen() && !(F4 && g_news_blocked) && !g_trading_stopped_by_max_dd) ? 1.0 : 0.15;

   double composite = (trendFactor*0.35) + (rsiFactor*0.25) + (volFactor*0.20) + (gateFactor*0.20);
   return MathMax(0.0, MathMin(1.0, composite));
}

void UpdateConfidenceArc()
{
   double raw = ComputeConfidenceScore();
   g_conf_smoothed += (raw - g_conf_smoothed) * 0.10;

   int litSegs = (int)MathRound(g_conf_smoothed * CONF_SEGS);
   color tierColors[10] = {CONF_T0, CONF_T1, CONF_T2, CONF_T3, CONF_T4, CONF_T5, CONF_T6, CONF_T7, CONF_T8, CONF_T9};

   for(int i = 0; i < CONF_SEGS; i++)
   {
      string nm = DB_PREFIX+"conf_seg_"+IntegerToString(i);
      int tierIdx = (int)MathFloor(((double)i / CONF_SEGS) * 10);
      tierIdx = MathMax(0, MathMin(9, tierIdx));
      if(i < litSegs)
      {
         color base = tierColors[tierIdx];
         if(i == litSegs - 1)
         {
            double glow = BreathWave(AnimationTick * 0.4);
            base = BlendColor(base, C_WHITE, glow*0.35);
         }
         UpdRect(nm, base);
      }
      else
      {
         UpdRect(nm, C_CHARCOAL2);
      }
   }

   color valClr = (g_conf_smoothed > 0.66) ? C_NEONMINT : (g_conf_smoothed > 0.33) ? C_GOLDBRIGHT : C_RED_BAD;
   UpdLbl(DB_PREFIX+"conf_val", DoubleToString(g_conf_smoothed*100.0,0)+"%", valClr);
   UpdLbl(DB_PREFIX+"v_conf2", DoubleToString(g_conf_smoothed*100.0,0)+"%", valClr);
}

//===================================================================
//  DATA-RAIN — an ambient vertical accent strip of falling glyphs
//  along the panel's far-right edge (just left of the risk
//  thermometer). Purely decorative reinforcement of the AI/quant
//  identity; each drop wraps back to the top once it exits the
//  bottom of the panel's live-data zone.
//===================================================================
void BuildDataRain()
{
   int w = DashboardWidth;
   int colTopY = DB_Y + DashboardHeight - 48;
   g_rain_top    = colTopY + 14;
   g_rain_bottom = 170;

   MathSrand((int)TimeLocal());

   for(int c = 0; c < RAIN_COLS; c++)
   {
      g_rain_x[c] = DB_X + w - 70 + c*10;
      for(int d = 0; d < RAIN_DROPS_PER_COL; d++)
      {
         int idx = c*RAIN_DROPS_PER_COL + d;
         g_rain_y[idx] = g_rain_bottom + (MathRand() % MathMax(1,(g_rain_top - g_rain_bottom)));
         g_rain_speed[idx] = 0.6 + (MathRand() % 100) / 140.0;
         string nm = DB_PREFIX+"rain_"+IntegerToString(idx);
         string glyph = ((MathRand() % 2) == 0) ? "1" : "0";
         CreateLabelLower(nm, glyph, g_rain_x[c], g_rain_y[idx], FS_RAIN, C_NEONMINTDIM, false);
      }
   }
}

void UpdateDataRain()
{
   int speed = MathMax(1, AnimationSpeed);
   for(int c = 0; c < RAIN_COLS; c++)
   {
      for(int d = 0; d < RAIN_DROPS_PER_COL; d++)
      {
         int idx = c*RAIN_DROPS_PER_COL + d;
         g_rain_y[idx] -= (int)MathRound(g_rain_speed[idx]*speed);
         if(g_rain_y[idx] < g_rain_bottom)
         {
            g_rain_y[idx] = g_rain_top;
            string nm2 = DB_PREFIX+"rain_"+IntegerToString(idx);
            string glyph = ((MathRand() % 2) == 0) ? "1" : "0";
            ObjectSetString(0, nm2, OBJPROP_TEXT, glyph);
         }
         string nm = DB_PREFIX+"rain_"+IntegerToString(idx);
         ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, g_rain_y[idx]);

         double headFrac = (double)(g_rain_y[idx]-g_rain_bottom) / MathMax(1,(g_rain_top-g_rain_bottom));
         color clr = BlendColor(C_NEONMINTDIM, C_NEONMINT, headFrac);
         ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
      }
   }
}

void UpdatePerformanceStats()
{
   if(!HistorySelect(0, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   if(total == g_history_deals_scanned) return;
   g_history_deals_scanned = total;

   g_win_count = 0; g_loss_count = 0; g_total_closed = 0;
   g_best_trade = 0.0; g_worst_trade = 0.0; g_streak_type = 0; g_streak_count = 0;
   g_gross_profit = 0.0; g_gross_loss = 0.0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(!IsOurMagic(magic)) continue;

      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(symbol != _Symbol) continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                       HistoryDealGetDouble(ticket, DEAL_SWAP) +
                       HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      if(profit > 0) { g_win_count++;  g_gross_profit += profit; }
      else           { g_loss_count++; g_gross_loss   += MathAbs(profit); }
      g_total_closed++;

      if(profit > g_best_trade)  g_best_trade  = profit;
      if(profit < g_worst_trade) g_worst_trade = profit;

      int thisType = (profit >= 0) ? 1 : -1;
      if(thisType == g_streak_type) g_streak_count++;
      else { g_streak_type = thisType; g_streak_count = 1; }
   }
}

void RefreshDashboard()
{
   UpdateNewsState(false);
   if(ShowDashboard)
   {
      UpdateDashboard();
      UpdateSpinner();
      UpdateHexCore();
      AnimateCornerGlow();
      AnimateHeaderScan();
      if(ShowAdvancedPanels)
      {
         UpdateSparkline();
         UpdateGridLadder();
         UpdateRiskMeter();
         UpdateTicker();
      }
      if(ShowSessionClock)     UpdateSessionClock();
      if(ShowMarketPulse)      UpdateMarketPulse();
      if(ShowVolatilityGauge)  UpdateVolatilityGauge();
      if(ShowConfidenceArc)    UpdateConfidenceArc();
      if(ShowDataRain)         UpdateDataRain();
   }
   if(ShowVertexIQ)  UpdateVertexIQ();
}

void UpdateDashboard()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > PeakEquity) PeakEquity = eq;

   UpdatePerformanceStats();
   UpdateChaseEdges();

   UpdLbl(DB_PREFIX+"v_state", StateToText(g_state), C_GOLDBRIGHT);

   int buyCt  = GetPositionCount(POSITION_TYPE_BUY);
   int sellCt = GetPositionCount(POSITION_TYPE_SELL);
   string basketStr = (buyCt>0) ? "BUY ACTIVE" : (sellCt>0) ? "SELL ACTIVE" : "NONE";
   color  basketClr = (buyCt>0) ? C_GREEN_OK : (sellCt>0) ? C_RED_BAD : C_SLATE;
   UpdLbl(DB_PREFIX+"v_basket", basketStr, basketClr);

   bool inSess = IsTradingSessionOpen();
   UpdLbl(DB_PREFIX+"v_sess", inSess?(F1?"ACTIVE":"ACTIVE (24/7)"):"CLOSED", inSess?C_GREEN_OK:C_SLATE);

   string newsStr; color newsClr;
   if(!F4)               { newsStr="OFF";     newsClr=C_SLATE; }
   else if(g_news_blocked){ newsStr="BLOCKED"; newsClr=C_RED_BAD; }
   else                   { newsStr="CLEAR";   newsClr=C_GREEN_OK; }
   UpdLbl(DB_PREFIX+"v_news", newsStr, newsClr);

   string guardStr; color guardClr;
   if(g_max_dd_emergency_active) { guardStr="EMERGENCY"; guardClr=C_RED_BAD; }
   else if(g_trading_stopped_by_max_dd) { guardStr="STOPPED"; guardClr=C_RED_BAD; }
   else if(InpEnableMaxDDProtection)    { guardStr="ARMED"; guardClr=C_GREEN_OK; }
   else                                  { guardStr="OFF"; guardClr=C_SLATE; }
   UpdLbl(DB_PREFIX+"v_guard", guardStr, guardClr);
   UpdLbl(DB_PREFIX+"v_grd2",  guardStr, guardClr);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   UpdLbl(DB_PREFIX+"v_spr", DoubleToString(spread,2), (spread>P1)?C_RED_BAD:C_IVORY);

   string arrowsStr = ShowTradeArrows ? (AutoCleanArrows ? "SHOWN (auto-clean)" : "SHOWN") : "HIDDEN";
   color  arrowsClr = ShowTradeArrows ? C_GREEN_OK : C_SLATE;
   UpdLbl(DB_PREFIX+"v_arrows", arrowsStr, arrowsClr);

   UpdLbl(DB_PREFIX+"v_ilot", DoubleToString(GetConfiguredInitialLot(),2), C_IVORY);

   UpdLbl(DB_PREFIX+"v_bal", "$"+DoubleToString(bal,2), C_GOLDBRIGHT);
   UpdLbl(DB_PREFIX+"v_eq",  "$"+DoubleToString(eq,2), C_IVORY);

   double todayPL = GetTodayRealizedProfit();
   string plStr = (todayPL >= 0) ? "+$" : "-$";
   plStr += DoubleToString(MathAbs(todayPL),2);
   UpdLbl(DB_PREFIX+"v_pl", plStr, (todayPL>=0)?C_GREEN_OK:C_RED_BAD);

   double openPL = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
         if(m_position.Symbol()==_Symbol && IsOurMagic(m_position.Magic()))
            openPL += m_position.Profit() + m_position.Swap();
   }
   UpdLbl(DB_PREFIX+"v_openpl", "$"+DoubleToString(openPL,2), (openPL>=0)?C_GREEN_OK:C_RED_BAD);
   UpdLbl(DB_PREFIX+"v_peak", "$"+DoubleToString(PeakEquity,2), C_IVORY);

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   UpdLbl(DB_PREFIX+"v_fm", "$"+DoubleToString(freeMargin,2), (freeMargin<0)?C_RED_BAD:C_IVORY);

   UpdLbl(DB_PREFIX+"v_win", IntegerToString(g_win_count)+" / "+IntegerToString(g_loss_count), C_IVORY);
   UpdLbl(DB_PREFIX+"v_total", IntegerToString(g_total_closed), C_IVORY);

   double winRate = (g_total_closed>0) ? (double)g_win_count/g_total_closed*100.0 : 0.0;
   color wrClr = (winRate>=60)?C_GOLDBRIGHT:(winRate>=40)?C_IVORY:C_SLATE;
   UpdLbl(DB_PREFIX+"v_wr", DoubleToString(winRate,1)+"%", wrClr);

   int openCt = buyCt + sellCt;
   UpdLbl(DB_PREFIX+"v_open", IntegerToString(openCt), (openCt>0)?C_GOLDBRIGHT:C_SLATE);

   double ddPct = GetCurrentDrawdownPercent();
   UpdLbl(DB_PREFIX+"v_ddpct", DoubleToString(ddPct,1)+"%", (ddPct>InpMaxDrawdownPercent*0.6 && InpEnableMaxDDProtection)?C_RED_BAD:C_IVORY);

   string sysStatus; color sysClr;
   if(g_max_dd_emergency_active)   { sysStatus="EMERGENCY";    sysClr=C_RED_BAD; }
   else if(g_trading_stopped_by_max_dd) { sysStatus="DD STOPPED"; sysClr=C_RED_BAD; }
   else if(spread>P1)              { sysStatus="SPREAD ALERT"; sysClr=C_RED_BAD; }
   else if(ddPct>InpMaxDrawdownPercent*0.6 && InpEnableMaxDDProtection) { sysStatus="DD WARNING"; sysClr=C_EMBER; }
   else if(g_news_blocked && F4)   { sysStatus="NEWS BLOCK";   sysClr=C_EMBER; }
   else if(openCt>=5)              { sysStatus="CAPACITY";     sysClr=C_IVORY; }
   else                             { sysStatus="NOMINAL";      sysClr=C_GREEN_OK; }
   UpdLbl(DB_PREFIX+"v_status", sysStatus, sysClr);

   string pfStr; color pfClr;
   if(g_gross_loss > 0)
   {
      double pf = g_gross_profit / g_gross_loss;
      pfStr = DoubleToString(pf,2);
      pfClr = (pf>=1.5) ? C_GREEN_OK : (pf>=1.0) ? C_IVORY : C_RED_BAD;
   }
   else
   {
      pfStr = (g_gross_profit>0) ? "INF" : "--";
      pfClr = (g_gross_profit>0) ? C_GREEN_OK : C_SLATE;
   }
   UpdLbl(DB_PREFIX+"v_pf", pfStr, pfClr);

   string streakStr = (g_streak_count==0) ? "--" : (IntegerToString(g_streak_count)+(g_streak_type>0?"W":"L"));
   color  streakClr = (g_streak_type>0) ? C_GREEN_OK : (g_streak_type<0 ? C_RED_BAD : C_SLATE);
   UpdLbl(DB_PREFIX+"v_streak", streakStr, streakClr);

   double hbGlow = BreathWave(AnimationTick * 0.5);
   UpdRect(DB_PREFIX+"hb_dot", BlendColor(C_GOLDDIM, C_GOLDBRIGHT, hbGlow));

   double upCount = 0, dnCount = 0;
   for(int i = 1; i <= 20; i++)
   {
      double c = iClose(_Symbol, PERIOD_H1, i);
      double o = iOpen(_Symbol,  PERIOD_H1, i);
      double h2 = iHigh(_Symbol,  PERIOD_H1, i);
      double l = iLow(_Symbol,   PERIOD_H1, i);
      double range = h2 - l;
      if(range > 0) { upCount += MathMax(c-o,0)/range; dnCount += MathMax(o-c,0)/range; }
   }
   double tot = upCount + dnCount;
   double rawBull = (tot > 0) ? upCount/tot : 0.5;
   double rawBear = (tot > 0) ? dnCount/tot : 0.5;
   if(PressureSmooth < 5) PressureSmooth++;
   BullPressure += (rawBull - BullPressure) / PressureSmooth;
   BearPressure += (rawBear - BearPressure) / PressureSmooth;

   int gaugeW = 240;
   int bullW = (int)MathMax(2, BullPressure/(BullPressure+BearPressure+0.0001) * gaugeW);
   int bearW = gaugeW - bullW;
   ObjectSetInteger(0, DB_PREFIX+"gauge_bull", OBJPROP_XSIZE, bullW);
   ObjectSetInteger(0, DB_PREFIX+"gauge_bear", OBJPROP_XSIZE, MathMax(2,bearW));
   ObjectSetInteger(0, DB_PREFIX+"gauge_bear", OBJPROP_XDISTANCE, DB_X+16+150+bullW);
   ObjectSetInteger(0, DB_PREFIX+"gauge_marker", OBJPROP_XDISTANCE, DB_X+16+150+bullW-1);

   AnimationTick = (AnimationTick + MathMax(1,AnimationSpeed)) % 200;
   bool active = (openCt > 0);
   double headerGlow = BreathWave(AnimationTick * 0.31);
   color pulse = active ? BlendColor(C_GOLD, C_GOLDBRIGHT, headerGlow) : C_GOLD;
   ObjectSetInteger(0, DB_PREFIX+"hdr", OBJPROP_COLOR, pulse);
   bool dotOn = (AnimationTick % 10) < 6;
   ObjectSetInteger(0, DB_PREFIX+"livedot", OBJPROP_BGCOLOR, dotOn ? (color)C_GREEN_OK : (color)C_CHARCOAL2);
   ObjectSetInteger(0, DB_PREFIX+"bal_accent", OBJPROP_BGCOLOR, pulse);

   ChartRedraw();
}

//===================================================================
//  VERTEX-IQ — compact heat-matrix strip embedded beneath the Grid
//  Ladder Projector, with dual-axis sweep and particle trails.
//===================================================================
color VtxHeatColor(double v)
{
   if(v < 0.05) return VTX_T0;
   if(v < 0.14) return VTX_T1;
   if(v < 0.24) return VTX_T2;
   if(v < 0.34) return VTX_T3;
   if(v < 0.44) return VTX_T4;
   if(v < 0.54) return VTX_T5;
   if(v < 0.64) return VTX_T6;
   if(v < 0.74) return VTX_T7;
   if(v < 0.84) return VTX_T8;
   if(v < 0.94) return VTX_T9;
   return VTX_T10;
}

void InitVertexData()
{
   int cols = MathMin(VertexCols, 6);
   int rows = MathMin(VertexRows, 20);
   for(int c = 0; c < cols; c++)
   {
      VX_ColBase[c] = 0.3 + c * 0.08;
      for(int r = 0; r < rows; r++)
      {
         VX_Grid[c][r]       = MathAbs(MathSin((double)(c * 7 + r * 3))) * 0.6;
         VX_GridTarget[c][r] = VX_Grid[c][r];
      }
   }
   for(int p = 0; p < 4; p++)
   {
      VX_ParticleRow[p]  = p * (rows / 4);
      VX_ParticleCol[p]  = p * 2;
      VX_ParticleHeat[p] = 0.85 + p * 0.03;
   }
}

void SampleVertexData()
{
   int cols = MathMin(VertexCols, 6);
   ENUM_TIMEFRAMES tfMap[6] = {PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_H1};

   for(int c = 0; c < cols; c++)
   {
      double heat = 0.5;
      if(c == 5)
      {
         double rsiBuf[];
         ArraySetAsSeries(rsiBuf, true);
         if(g_rsi_handle != INVALID_HANDLE && CopyBuffer(g_rsi_handle, 0, 1, 1, rsiBuf) > 0)
            heat = rsiBuf[0] / 100.0;
      }
      else
      {
         ENUM_TIMEFRAMES tf = tfMap[c];
         double upSum = 0, dnSum = 0;
         for(int i = 1; i <= 8; i++)
         {
            double co = iOpen(_Symbol,  tf, i);
            double cc = iClose(_Symbol, tf, i);
            double ch = iHigh(_Symbol,  tf, i);
            double cl = iLow(_Symbol,   tf, i);
            double rng = ch - cl;
            if(rng > 0) { upSum += MathMax(cc-co,0)/rng; dnSum += MathMax(co-cc,0)/rng; }
         }
         double tot = upSum + dnSum;
         heat = (tot > 0) ? upSum / tot : 0.5;
      }
      VX_ColBase[c] = heat;
   }
}

void ComputeVertexGeometry()
{
   VX_Cols = MathMin(VertexCols, 6);
   VX_Rows = MathMin(VertexRows, 20);

   int c3x     = DB_X + 16 + 195 + 195;
   int colTopY = DB_Y + DashboardHeight - 48;
   int ladderBottomY = colTopY - (LADDER_LEVELS*22) - 10;

   VX_HeaderH = 16;
   VX_FooterH = 14;
   VX_BandGap = 2;

   VX_X = c3x - 4;
   VX_Y = 84;
   VX_W = 199;
   VX_H = ladderBottomY - VX_Y;
   if(VX_H < 70) VX_H = 70;

   int bandArea = VX_H - VX_HeaderH - VX_FooterH;
   VX_BandH = MathMax(5, (bandArea - (VX_Cols-1)*VX_BandGap) / MathMax(VX_Cols,1));

   VX_LabelW = 24;
   int cellAreaW = VX_W - VX_LabelW - 30;
   VX_CellW = MathMax(3, (cellAreaW - (VX_Rows-1)) / MathMax(VX_Rows,1));
}

void BuildVertexIQ()
{
   if(!ShowVertexIQ) return;

   ComputeVertexGeometry();

   CreateBackgroundPanelLower(VX_PREFIX+"bg_outer", VX_X, VX_Y, VX_W, VX_H, C_CHARCOAL, C_STEEL);
   CreateBackgroundPanelLower(VX_PREFIX+"bg_inner", VX_X+1, VX_Y+1, VX_W-2, VX_H-2, C_ONYX, C_DEEPCRIMSON);

   CreateBackgroundPanelLower(VX_PREFIX+"hdrstrip", VX_X+2, VX_Y+VX_H-VX_HeaderH, VX_W-4, VX_HeaderH-2, C_CHARCOAL2, C_OBSIDIAN);
   CreateLabelLower(VX_PREFIX+"hdr", "AXXA", VX_X+8, VX_Y+VX_H-VX_HeaderH+3, FS_VX_HDR-1, C_GOLDBRIGHT, true);
   CreateBackgroundPanelLower(VX_PREFIX+"HD_DOT", VX_X+VX_W-16, VX_Y+VX_H-VX_HeaderH+5, 6, 6, C_GOLD, C_OBSIDIAN);
   CreateBackgroundPanelLower(VX_PREFIX+"sweep", VX_X+2, VX_Y+VX_H-VX_HeaderH-2, 2, VX_H-VX_HeaderH-VX_FooterH, C_GOLDBRIGHT, C_OBSIDIAN);
   CreateBackgroundPanelLower(VX_PREFIX+"sweepV", VX_X+2, VX_Y+VX_FooterH, VX_W-4, 1, C_AZURE, C_OBSIDIAN);

   string colLabels[8] = {"M5","M15","M30","H1","H4","RSI","--","--"};

   int cellAreaX = VX_X + VX_LabelW;
   int gridTopY  = VX_Y + VX_H - VX_HeaderH;

   for(int c = 0; c < VX_Cols; c++)
   {
      int bandBottomY = gridTopY - (c+1)*(VX_BandH+VX_BandGap);
      CreateLabelLower(VX_PREFIX+"CL_"+IntegerToString(c), colLabels[c], VX_X+6, bandBottomY+1, FS_VX_COL, C_SLATE, true);
      for(int r = 0; r < VX_Rows; r++)
      {
         int cx = cellAreaX + r*(VX_CellW+1);
         CreateBackgroundPanelLower(VX_PREFIX+"CELL_"+IntegerToString(c)+"_"+IntegerToString(r), cx, bandBottomY, VX_CellW, VX_BandH, VTX_T0, C_OBSIDIAN);
      }
      CreateLabelLower(VX_PREFIX+"BV_"+IntegerToString(c), "--", VX_X+VX_W-30, bandBottomY+1, FS_VX_BAND, C_SLATE, true);
   }

   for(int p = 0; p < 4; p++)
      CreateBackgroundPanelLower(VX_PREFIX+"PART_"+IntegerToString(p), cellAreaX, gridTopY-VX_BandH, VX_CellW, VX_BandH, C_OBSIDIAN, C_OBSIDIAN);

   CreateBackgroundPanelLower(VX_PREFIX+"FT_BG",  VX_X+1, VX_Y+1, VX_W-2, VX_FooterH-2, C_CHARCOAL2, C_OBSIDIAN);
   color lgClrs[5] = {VTX_T1, VTX_T3, VTX_T5, VTX_T7, VTX_T10};
   for(int lg = 0; lg < 5; lg++)
      CreateBackgroundPanelLower(VX_PREFIX+"LG_"+IntegerToString(lg), VX_X+6+lg*10, VX_Y+4, 7, 6, lgClrs[lg], C_OBSIDIAN);
   CreateLabelLower(VX_PREFIX+"FT_IDX_L", "IDX:", VX_X+VX_W-70, VX_Y+4, FS_VX_FOOT, C_SLATE, false);
   CreateLabelLower(VX_PREFIX+"FT_IDX_V", "---", VX_X+VX_W-32, VX_Y+4, FS_VX_FOOT, C_IVORY, true);

   ChartRedraw();
}

void UpdateVertexIQ()
{
   int cols = VX_Cols;
   int rows = VX_Rows;
   int speed = MathMax(1, AnimationSpeed);

   VX_AnimTick += speed;
   VX_WaveOffset = VX_AnimTick % MathMax(rows,1);

   if(VX_AnimTick % 5 < speed) SampleVertexData();

   for(int c = 0; c < cols; c++)
   {
      double base = VX_ColBase[c];
      for(int r = 0; r < rows; r++)
      {
         double decay  = 1.0 - (double)r / (double)rows * 0.55;
         double wave   = MathSin((double)(r - VX_WaveOffset + c * 4) * 0.45) * 0.18;
         double target = MathMin(1.0, MathMax(0.0, base * decay + wave));
         VX_GridTarget[c][r] = target;
         VX_Grid[c][r] += (target - VX_Grid[c][r]) * 0.18;
      }
   }

   if(VX_AnimTick % 3 < speed)
   {
      for(int p = 0; p < 4; p++)
      {
         VX_ParticleRow[p]++;
         if(VX_ParticleRow[p] >= rows)
         {
            VX_ParticleRow[p]  = 0;
            VX_ParticleCol[p]  = (VX_ParticleCol[p] + 3) % MathMax(cols,1);
            VX_ParticleHeat[p] = 0.80 + (double)p * 0.04;
         }
         int pr = VX_ParticleRow[p];
         int pc = VX_ParticleCol[p];
         if(pr >= 0 && pr < rows && pc >= 0 && pc < cols)
            VX_Grid[pc][pr] = MathMin(1.0, VX_Grid[pc][pr] + VX_ParticleHeat[p] * 0.35);
         VX_ParticleHeat[p] *= 0.97;
         if(VX_ParticleHeat[p] < 0.2) VX_ParticleHeat[p] = 0.80;
      }
   }

   int cellAreaX = VX_X + VX_LabelW;
   int gridTopY  = VX_Y + VX_H - VX_HeaderH;

   for(int c = 0; c < cols; c++)
      for(int r = 0; r < rows; r++)
      {
         double v  = VX_Grid[c][r];
         string cn = VX_PREFIX+"CELL_"+IntegerToString(c)+"_"+IntegerToString(r);
         UpdRect(cn, VtxHeatColor(v));
      }

   for(int p = 0; p < 4; p++)
   {
      int pr = VX_ParticleRow[p];
      int pc = VX_ParticleCol[p];
      string pn = VX_PREFIX+"PART_"+IntegerToString(p);
      if(pr >= 0 && pr < rows && pc >= 0 && pc < cols)
      {
         int px = cellAreaX + pr*(VX_CellW+1);
         int py = gridTopY - (pc+1)*(VX_BandH+VX_BandGap);
         ObjectSetInteger(0, pn, OBJPROP_XDISTANCE, px);
         ObjectSetInteger(0, pn, OBJPROP_YDISTANCE, py);
         bool pFlash = (VX_AnimTick % 4 < 2);
         UpdRect(pn, pFlash ? VTX_T10 : VTX_T9);
      }
      else UpdRect(pn, C_OBSIDIAN);
   }

   color dotClr = (VX_AnimTick % 8 < 4) ? C_GOLDBRIGHT : C_GOLD;
   UpdRect(VX_PREFIX+"HD_DOT", dotClr);

   VX_SweepTick += 3*speed;
   int sweepRange = VX_W - 6;
   if(VX_SweepTick > sweepRange) VX_SweepTick = 0;
   ObjectSetInteger(0, VX_PREFIX+"sweep", OBJPROP_XDISTANCE, VX_X + 2 + VX_SweepTick);
   int sweepPhase = (VX_SweepTick / 30) % 2;
   ObjectSetInteger(0, VX_PREFIX+"sweep", OBJPROP_BGCOLOR, (sweepPhase==0) ? C_GOLDBRIGHT : C_CRIMSON);

   VX_SweepTickV += 2*speed;
   int sweepRangeV = VX_H - VX_HeaderH - VX_FooterH;
   if(VX_SweepTickV > sweepRangeV) VX_SweepTickV = 0;
   ObjectSetInteger(0, VX_PREFIX+"sweepV", OBJPROP_YDISTANCE, VX_Y + VX_FooterH + VX_SweepTickV);
   double sweepGlowV = BreathWave(VX_AnimTick * 0.2);
   ObjectSetInteger(0, VX_PREFIX+"sweepV", OBJPROP_BGCOLOR, BlendColor(C_AZUREDIM, C_AZURE, sweepGlowV));

   for(int c = 0; c < cols; c++)
   {
      double colHeat = VX_ColBase[c];
      color clClr = (colHeat > 0.65) ? C_GOLDBRIGHT : (colHeat > 0.45) ? C_IVORY : C_SLATE;
      ObjectSetInteger(0, VX_PREFIX+"CL_"+IntegerToString(c), OBJPROP_COLOR, clClr);

      string bvStr = IntegerToString((int)(colHeat*100))+"%";
      UpdLbl(VX_PREFIX+"BV_"+IntegerToString(c), bvStr, clClr);
   }

   double totalHeat = 0; int cellCount = 0;
   for(int c = 0; c < cols; c++)
      for(int r = 0; r < rows; r++) { totalHeat += VX_Grid[c][r]; cellCount++; }
   double avgHeat = (cellCount > 0) ? totalHeat / cellCount : 0.0;
   string idxStr = IntegerToString((int)(avgHeat * 100)) + "%";
   color  idxClr = (avgHeat > 0.65) ? C_GOLDBRIGHT : (avgHeat > 0.45) ? C_IVORY : C_SLATE;
   UpdLbl(VX_PREFIX+"FT_IDX_V", idxStr, idxClr);

   ChartRedraw();
}

void DeleteAllDashboard()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total-1; i >= 0; i--)
   {
      string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, DB_PREFIX) == 0 || StringFind(nm, VX_PREFIX) == 0)
         ObjectDelete(0, nm);
   }
   ChartRedraw();
}
//+------------------------------------------------------------------+
