-module(secdb_filters).
-author('Max Lapshin <max@maxidoors.ru>').

-include("../include/secdb.hrl").
-include_lib("eunit/include/eunit.hrl").


-export([candle/2, count/2, drop/2, last/2]).
% -export([average/2]).

-record(can, {
    type     = md :: md | trade | all,
    period   = 30000,
    ref_time = undefined,
    current_segment,
    open,
    high,
    low,
    close
}).

parse_options([], #can{} = Candle) ->
  Candle;
parse_options([{period, Period}|MoreOpts], #can{} = Candle) ->
  parse_options(MoreOpts, Candle#can{period = Period});
parse_options([{type, T} | MoreOpts], #can{} = Candle) when T=:=md; T=:=trade; T=:=all ->
  parse_options(MoreOpts, Candle#can{type = T});
parse_options([{ref_time, Time}|T], #can{} = Candle) when Time == start; Time == finish ->
  parse_options(T, Candle#can{ref_time = Time}).


candle(Event, undefined) ->
  candle2(Event, []);
candle(Event, Opts) when is_list(Opts) ->
  Candle = parse_options(Opts, #can{}), 
  candle2(Event, Candle).

candle2(Event = #md{},    #can{type = Type} = Candle) when Type =/= md ->
  {[Event], Candle};
candle2(Event = #trade{}, #can{type = Type} = Candle) when Type =/= trade ->
  {[Event], Candle};
candle2(eof, #can{} = Candle) ->
  flush_segment(Candle);
candle2(Other, #can{} = Candle) when not is_record(Other,md), not is_record(Other,trade) ->
  {[Other], Candle};
candle2(Packet, #can{open = undefined, period = undefined} = Candle) ->
  {[], start_segment(undefined, Packet, Candle)};
candle2(Packet, #can{open = undefined, period = Period} = Candle) when is_integer(Period) ->
  {[], start_segment(timestamp(Packet) div Period, Packet, Candle)};
candle2(Packet, #can{period = undefined} = Candle) ->
  {[], candle_accumulate(Packet, Candle)};
candle2(Packet, #can{period = Period, current_segment = Seg} = Candle)
  when is_number(Period) andalso (is_record(Packet, md) orelse is_record(Packet,trade)) ->
  case timestamp(Packet) div Period of
    Seg ->
      {[], candle_accumulate(Packet, Candle)};
    NewSeg ->
      {Events, Candle1} = flush_segment(Candle),
      {Events, start_segment(NewSeg, Packet, Candle1)}
  end.

start_segment(Segment, Pkt, Candle) ->
  Opened = Candle#can{current_segment = Segment, open = Pkt, high = Pkt, low = Pkt, close = Pkt},
  candle_accumulate(Pkt, Opened).

% Flush segment if data is collected
flush_segment(#can{open = undefined} = Candle) ->
  % Segment is not opened, do nothing
  {[], Candle};

flush_segment(#can{ref_time = RefTime, current_segment = Segment, period = Period,
                   open = Open, high = High, low = Low, close = Close} = Candle)
when RefTime == start; RefTime == finish ->
  % User has requested specific reference time, so we return 5-tuple of {Time, Open, High, Low, Close}
  Timestamp = case RefTime of
    start -> Segment * Period;
    finish -> (Segment+1) * Period
  end,
  OHLC = {Timestamp, value(open, Open), value(high, High), value(low, Low), value(close, Close)},
  {[OHLC], empty(Candle)};

flush_segment(#can{open = Open, high = High, low = Low, close = Close} = Candle) ->
  % By default, return every event as is
  Events = lists:sort([Open, High, Low, Close]), % UTC field is just after (common) type, so events are sorted chronologically
  {Events, empty(Candle)}.


empty(#can{} = Candle) ->
  Candle#can{
    open = undefined,
    high = undefined,
    low = undefined,
    close = undefined
  }.


candle_accumulate(Packet, #can{high = High, low = Low} = Candle) ->
  Candle#can{high = highest(High, Packet), low = lowest(Low, Packet), close = Packet}.


highest(undefined, Packet) ->
  Packet;
highest(#md{ask = [{AskL, _}|_]}, #md{ask = [{AskH,_}|_]} = Highest) when AskH > AskL ->
  Highest;
highest(#trade{price = PriceL}, #trade{price = PriceH} = Highest) when PriceH > PriceL ->
  Highest;
highest(Anything, _NoMatter) ->
  Anything.


lowest(undefined, Packet) ->
  Packet;
lowest(#md{bid = [{BidH, _}|_]}, #md{bid = [{BidL,_}|_]} = Lowest) when BidH > BidL ->
  Lowest;
lowest(#trade{price = PriceH}, #trade{price = PriceL} = Lowest) when PriceH > PriceL ->
  Lowest;
lowest(Anything, _NoMatter) ->
  Anything.


timestamp(#md{timestamp = Timestamp}) -> Timestamp;
timestamp(#trade{timestamp = Timestamp}) -> Timestamp.

value(_, #trade{price = Price})      -> Price;
value(high, #md{ask = [{Ask, _}|_]}) -> Ask;
value(low,  #md{bid = [{Bid, _}|_]}) -> Bid;
value(_,    #md{}   = MD)            -> (value(high, MD) + value(low, MD))/2.

test_candle(Input) ->
  test_candle(Input, undefined).

test_candle(Input, State0) ->
  {MDList, _} = lists:mapfoldl(fun({Bid, Ask}, N) ->
        MD = #md{timestamp = N, bid = [{Bid,0}], ask = [{Ask,0}]},
        {MD, N+1}
    end, 1, Input),
  Events = run_filter(fun candle/2, State0, MDList, []),
  ?assertNot(lists:member(undefined, Events)),
  [{Bid,Ask} || #md{bid = [{Bid,_}], ask = [{Ask,_}]} <- Events].

test_trade_candle(Input) ->
  {TradeList, _} = lists:mapfoldl(fun(Price, N) ->
        {#trade{timestamp = N, price = Price, volume = 1}, N+1}
    end, 1, Input),
  Events = run_filter(fun candle/2, [{type, trade}], TradeList, []),
  ?assertNot(lists:member(undefined, Events)),
  [Price || #trade{price = Price} <- Events].


run_filter(Fun, State, [Event|List], Acc) ->
  {Events, State1} = Fun(Event, State),
  run_filter(Fun, State1, List, Acc ++ Events);

run_filter(Fun, State, [], Acc) ->
  {Events, _State1} = Fun(eof, State),
  Acc ++ Events.

candle_test() ->
  % Now (after 6d015e7) candle always returns 4 events -- Open may be high, low or even close, etc.
  ?assertEqual([{1,5}, {0,4}, {10,14}, {8,12}], test_candle([{1,5},{2,8},{3,4},{0,4},{5,11},{10,14},{1,9},{8,12}])),
  ?assertEqual([{1,5}, {0,4}, {8,12}, {8,12}], test_candle([{1,5},{2,8},{3,4},{0,4},{5,11},{8,12}])),
  ?assertEqual([{1,5}, {1,5}, {8,12}, {8,12}], test_candle([{1,5},{2,8},{3,4},{5,11},{8,12}])),
  
  ?assertEqual([1, 0, 10, 8], test_trade_candle([1,2,3,0,5,10,1,8])),
  ?assertEqual([1, 0, 8, 8], test_trade_candle([1,2,3,0,5,8])),
  ?assertEqual([1, 1, 8, 8], test_trade_candle([1,2,3,1,5,8])),

  N = 100000,
  List = [begin
    Bid = random:uniform(1000),
    Ask = Bid + random:uniform(20),
    {md,I, [{Bid,0}], [{Ask,0}]}
  end || I <- lists:seq(1,N)],
  T1 = erlang:now(),
  S2 = lists:foldl(fun(MD, S) ->
    {_, S1} = candle(MD, S),
    S1
  end, undefined, List),
  {_, _} = candle(eof, S2),
  T2 = erlang:now(),
  Delta = timer:now_diff(T2,T1),
  ?debugFmt("Candle bm: ~B: ~B ms", [N, Delta]),
  ok.

candle_pass_foreign_test() ->
  ?assertMatch({[#trade{}], #can{}}, candle(#trade{}, [{type, md}])),
  ?assertMatch({[#md{}], #can{}}, candle(#md{}, [{type, trade}])),
  ok.

candle_no_undefined_test() ->
  % Test candle does not return anything on empty data
  ?assertEqual([], test_candle([])),
  % Test candle on poor periods
  ?assertEqual([{1,5}, {1,5}, {1,5}, {1,5}], test_candle([{1,5}])),
  ?assertEqual([{1,5}, {1,5}, {1,5}, {2,4}], test_candle([{1,5}, {2,4}])), % Second event does not compare more or less than first
  ?assertEqual([{1,5}, {1,5}, {2,6}, {2,6}], test_candle([{1,5}, {2,6}])), % Close = High
  ?assertEqual([{2,5}, {2,5}, {1,4}, {3,4}], test_candle([{2,5}, {1,4}, {3,4}])), % Take Low

  ?assertEqual([ % Make two periods, each has one event
      {1,5}, {1,5}, {1,5}, {1,5}, % First period is only one event (timestamps start with 1)
      {2,8}, {2,8}, {2,8}, {2,8}], test_candle([{1,5},{2,8}], [{period, 2}])),
  ?assertEqual([ % Same, but second period has 2 events
      {1,5}, {1,5}, {1,5}, {1,5}, % First period is only one event (timestamps start with 1)
      {2,8}, {2,8}, {1,7}, {1,7}], test_candle([{1,5},{2,8},{1,7}], [{period, 2}])),
  ok.


count(eof, Count) ->
  {[Count], Count};
count(_Event, Count) ->
  {[], Count + 1}.

drop(#md{}, md) ->
  {[], md};
drop(#trade{}, trade) ->
  {[], trade};
drop(eof, What) ->
  {[], What};
drop(Other, What) ->
  {[Other], What}.


last(Event, Type) when is_atom(Type) ->
  last(Event, {Type, undefined});
last(eof, {Type, Event}) ->
  {[Event], Type};
last({Type, _, _, _} = Event, {Type, _}) ->
  {[], {Type, Event}};
last(_, State) ->
  {[], State}.
