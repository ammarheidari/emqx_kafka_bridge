%%--------------------------------------------------------------------
%% Copyright (c) 2015-2017 Feng Lee <feng@emqtt.io>.
%%
%% Modified by Ramez Hanna <rhanna@iotblue.net>
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_kafka_bridge).

-include("emqx_kafka_bridge.hrl").

-include_lib("emqx/include/emqx.hrl").

-export([load/1, unload/0]).

%% Hooks functions

-export([on_client_connected/4, on_client_disconnected/3]).

% -export([on_client_subscribe/3, on_client_unsubscribe/3]).

% -export([on_session_created/3, on_session_terminated/3]).

-export([on_session_subscribed/4, on_session_unsubscribed/4]).

-export([on_message_publish/2, on_message_delivered/3]).

%% Called when the plugin application start
load(Env) ->
    ekaf_init([Env]),
    emqx:hook('client.connected', fun ?MODULE:on_client_connected/4, [Env]),
    emqx:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
    % emqx:hook('client.subscribe', fun ?MODULE:on_client_subscribe/3, [Env]),
    % emqx:hook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/3, [Env]),
    emqx:hook('session.subscribed', fun ?MODULE:on_session_subscribed/4, [Env]),
    emqx:hook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4, [Env]),
    % emqx:hook('session.created', fun ?MODULE:on_session_created/3, [Env]),
    % emqx:hook('session.terminated', fun ?MODULE:on_session_terminated/3, [Env]),
    % emqx:hook('message.acked', fun ?MODULE:on_message_acked/3, [Env]),
    emqx:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
    emqx:hook('message.delivered', fun ?MODULE:on_message_delivered/3, [Env]).

on_client_connected(#{client_id := ClientId, username := Username}, ConnAck, _ConnAttrs, _Env) ->
    if
        ConnAck == 0 ->
            io:format("client ~s/~s will connected ~n", [ClientId, Username]),
            Event = [{clientid, ClientId},
                        {username, Username},
                        {ts, timestamp()}],
            produce_kafka_connected(Event);
        true ->
            io:format("client ~s/~s connected error ~p~n", [ClientId, Username, ConnAck])
    end,
    ok.

on_client_disconnected(#{client_id := ClientId, username := Username}, _Reason, _Env) ->
    % io:format("client ~s/~s disconnected ~n", [ClientId, Username]),
    Event = [{clientid, ClientId},
                {username, Username},
                {ts, timestamp()}],
    produce_kafka_disconnected(Event),
    ok.

% on_client_subscribe(#{client_id := ClientId, username := Username}, TopicTable, _Env) ->
%     io:format("client(~s/~s) will subscribe: ~p~n", [Username, ClientId, TopicTable]),
%     Event = [{clientid, ClientId},
%                 {username, Username},
%                 {topic, TopicTable},
%                 {ts, timestamp()}],
%     produce_kafka_subscribe(Event),
%     {ok, TopicTable}.
    
% on_client_unsubscribe(#{client_id := ClientId, username := Username}, TopicTable, _Env) ->
%     io:format("client(~s/~s) unsubscribe ~p~n", [ClientId, Username, TopicTable]),
%     Event = [{clientid, ClientId},
%                 {username, Username},
%                 {topic, TopicTable},
%                 {ts, timestamp()}],
%     produce_kafka_unsubscribe(Event),
%     {ok, TopicTable}.

% on_session_created(#{client_id := ClientId}, SessAttrs, _Env) ->
%     [_, _, _, {_, Username} | _] = SessAttrs,
%     % io:format("session(~s/~s) created~n", [ClientId, Username]),
%     Event = [{clientid, ClientId},
%                 {username, Username},
%                 {ts, timestamp()}],
%     produce_kafka_session_created(Event).

% on_session_terminated(#{client_id := ClientId, username := Username}, _ReasonCode, _Env) ->
%     % io:format("Session(~s/~s) terminated: .", [ClientId, Username]),
%     Event = [{clientid, ClientId},
%                 {username, Username},
%                 {ts, timestamp()}],
%     produce_kafka_session_terminated(Event).

on_session_subscribed(#{client_id := ClientId, username := Username}, Topic, _SubOpts, _Env) ->
    % io:format("session(~s/~s) subscribed: ~p~n", [Username, ClientId, {Topic, SubOpts}]),
    Event = [{clientid, ClientId},
            {username, Username},
            {topic, Topic},
            {ts, timestamp()}],
    produce_kafka_subscribe(Event).

on_session_unsubscribed(#{client_id := ClientId, username := Username}, Topic, _Opts, _Env) ->
    % io:format("session(~s/~s) unsubscribed: ~p~n", [Username, ClientId, {Topic, Opts}]),
    Event = [{clientid, ClientId},
                {username, Username},
                {topic, Topic},
                {ts, timestamp()}],
    produce_kafka_unsubscribe(Event).

%% transform message and return
on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message, _Env) ->
    {ok, Payload} = format_payload(Message),
    produce_kafka_publish(Payload),
    {ok, Message}.

on_message_delivered(#{client_id := ClientId, username := Username}, Message, _Env) ->
    % io:format("delivered to client(~s/~s): ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    Event = [{clientid, ClientId},
                {username, Username},
                {topic, Message#message.topic},
                {size, byte_size(Message#message.payload)},
                {ts, emqx_time:now_secs(Message#message.timestamp)}],
    produce_kafka_delivered(Event),
    {ok, Message}.

% on_message_acked(ClientId, Username, Message, _Env) ->
%     % io:format("client(~s/~s) acked: ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
%     Event = [{action, <<"acked">>},
%                 {from_client_id, ClientId},
%                 {from_username, Username},
%                 {topic, Message#message.topic},
%                 {qos, Message#message.qos},
%                 {message, Message#message.payload}],
%     produce_kafka_log(Event),
%     {ok, Message}.

ekaf_init(_Env) ->
    {ok, BrokerValues} = application:get_env(emqx_kafka_bridge, broker),
    KafkaHost = proplists:get_value(host, BrokerValues),
    KafkaPort = proplists:get_value(port, BrokerValues),
    io:format("connect to kafka ~s~n", [KafkaHost]),
    KafkaPartitionStrategy = proplists:get_value(partitionstrategy, BrokerValues),
    KafkaPartitionWorkers = proplists:get_value(partitionworkers, BrokerValues),
    %KafkaPayloadTopic = proplists:get_value(payloadtopic, BrokerValues),
    %KafkaEventTopic = proplists:get_value(eventtopic, BrokerValues),
    KafkaPublishTopic = proplists:get_value(publishtopic, BrokerValues),
    KafkaConnectedTopic = proplists:get_value(connectedtopic, BrokerValues),
    KafkaDisconnectedTopic = proplists:get_value(disconnectedtopic, BrokerValues),
    KafkaSubscribeTopic = proplists:get_value(subscribetopic, BrokerValues),
    KafkaUnsubscribeTopic = proplists:get_value(unsubscribetopic, BrokerValues),
    KafkaDeliveredTopic = proplists:get_value(deliveredtopic, BrokerValues),
    % KafkaSessionCreatedTopic = proplists:get_value(sessioncreatedtopic, BrokerValues),
    % KafkaSessionTerminatedTopic = proplists:get_value(sessionterminatedtopic, BrokerValues),
    application:set_env(ekaf, ekaf_bootstrap_broker, {KafkaHost, list_to_integer(KafkaPort)}),
    application:set_env(ekaf, ekaf_partition_strategy, list_to_atom(KafkaPartitionStrategy)),
    application:set_env(ekaf, ekaf_per_partition_workers, KafkaPartitionWorkers),
    application:set_env(ekaf, ekaf_per_partition_workers_max, 10),
    ets:new(topic_table, [named_table, protected, set, {keypos, 1}]),
    % ets:insert(topic_table, {kafka_payload_topic, KafkaPayloadTopic}),
    % ets:insert(topic_table, {kafka_event_topic, KafkaEventTopic}),
    ets:insert(topic_table, {kafka_publish_topic, KafkaPublishTopic}),
    ets:insert(topic_table, {kafka_connected_topic, KafkaConnectedTopic}),
    ets:insert(topic_table, {kafka_disconnected_topic, KafkaDisconnectedTopic}),
    ets:insert(topic_table, {kafka_subscribe_topic, KafkaSubscribeTopic}),
    ets:insert(topic_table, {kafka_unsubscribe_topic, KafkaUnsubscribeTopic}),
    ets:insert(topic_table, {kafka_delivered_topic, KafkaDeliveredTopic}),

    % ets:insert(topic_table, {kafka_session_created_topic, KafkaSessionCreatedTopic}),
    % ets:insert(topic_table, {kafka_session_terminated_topic, KafkaSessionTerminatedTopic}),

    % {ok, _} = application:ensure_all_started(kafkamocker),
    {ok, _} = application:ensure_all_started(gproc),
    % {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(ekaf).

format_payload(Message) ->
    {ClientId, Username} = format_from(Message#message.from),
    Payload = [{clientid, ClientId},
                  {username, Username},
                  {topic, Message#message.topic},
                  {payload, Message#message.payload},
                  {size, byte_size(Message#message.payload)},
                  {ts, emqx_time:now_secs(Message#message.timestamp)}],
    {ok, Payload}.

format_from({ClientId, Username}) ->
    {ClientId, Username};
format_from(From) when is_atom(From) ->
    {a2b(From), a2b(From)};
format_from(_) ->
    {<<>>, <<>>}.

a2b(A) -> erlang:atom_to_binary(A, utf8).

%% Called when the plugin application stop
unload() ->
    emqx:unhook('client.connected', fun ?MODULE:on_client_connected/4),
    emqx:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    % emqx:unhook('client.subscribe', fun ?MODULE:on_client_subscribe/3),
    % emqx:unhook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/3),
    emqx:unhook('session.subscribed', fun ?MODULE:on_session_subscribed/4),
    emqx:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
    % emqx:unhook('session.created', fun ?MODULE:on_session_created/3),
    % emqx:unhook('session.terminated', fun ?MODULE:on_session_terminated/3),
    emqx:unhook('message.publish', fun ?MODULE:on_message_publish/2),
    emqx:unhook('message.delivered', fun ?MODULE:on_message_delivered/3).
    %emqx:unhook('message.acked', fun ?MODULE:on_message_acked/4).


% produce_kafka_payload(Message) ->
%     [{_, Topic}] = ets:lookup(topic_table, kafka_payload_topic),
%     % Topic = <<"Processing">>,
%     % io:format("send to kafka event topic: byte size: ~p~n", [byte_size(list_to_binary(Topic))]),
%     % Payload = iolist_to_binary(mochijson2:encode(Message)),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

% produce_kafka_log(Message) ->
%     [{_, Topic}] = ets:lookup(topic_table, kafka_event_topic),
%     % Topic = <<"DeviceLog">>,
%     % io:format("send to kafka event topic: byte size: ~p~n", [byte_size(list_to_binary(Topic))]),
%     % Payload = iolist_to_binary(mochijson2:encode(Message)),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

produce_kafka_publish(Message) ->
    [{_, Topic}] = ets:lookup(topic_table, kafka_publish_topic),
    % io:format("send to kafka event topic: byte size: ~p~n", [list_to_binary(Topic)]),
    % Payload = iolist_to_binary(mochijson2:encode(Message)),
    Payload = jsx:encode(Message),
    ok = ekaf:produce_async(list_to_binary(Topic), Payload),
    ok.

produce_kafka_connected(Message) ->
    [{_, Topic}] = ets:lookup(topic_table, kafka_connected_topic),
    io:format("send to kafka event topic: byte size: ~p~n", [list_to_binary(Topic)]),
    % Payload = iolist_to_binary(mochijson2:encode(Message)),
    Payload = jsx:encode(Message),
    ok = ekaf:produce_async(list_to_binary(Topic), Payload),
    ok.

produce_kafka_disconnected(Message) ->
    [{_, Topic}] = ets:lookup(topic_table, kafka_disconnected_topic),
    io:format("send to kafka event topic: byte size: ~p~n", [list_to_binary(Topic)]),
    % Payload = iolist_to_binary(mochijson2:encode(Message)),
    Payload = jsx:encode(Message),
    ok = ekaf:produce_async(list_to_binary(Topic), Payload),
    ok.

produce_kafka_unsubscribe(Message) ->
    [{_, Topic}] = ets:lookup(topic_table, kafka_unsubscribe_topic),
    io:format("send to kafka event topic: byte size: ~p~n", [list_to_binary(Topic)]),
    % Payload = iolist_to_binary(mochijson2:encode(Message)),
    Payload = jsx:encode(Message),
    ok = ekaf:produce_async(list_to_binary(Topic), Payload),
    ok.

produce_kafka_subscribe(Message) ->
    [{_, Topic}] = ets:lookup(topic_table, kafka_subscribe_topic),
    io:format("send to kafka event topic: byte size: ~p~n", [list_to_binary(Topic)]),
    % Payload = iolist_to_binary(mochijson2:encode(Message)),
    Payload = jsx:encode(Message),
    ok = ekaf:produce_async(list_to_binary(Topic), Payload),
    ok.

produce_kafka_delivered(Message) ->
    [{_, Topic}] = ets:lookup(topic_table, kafka_delivered_topic),
    % io:format("send to kafka event topic: byte size: ~p~n", [byte_size(list_to_binary(Topic))]),
    % Payload = iolist_to_binary(mochijson2:encode(Message)),
    Payload = jsx:encode(Message),
    ok = ekaf:produce_async(list_to_binary(Topic), Payload),
    ok.

% produce_kafka_session_created(Message) ->
%     [{_, Topic}] = ets:lookup(topic_table, kafka_session_created_topic),
%     io:format("send to kafka event topic: byte size: ~p~n", [Topic]),
%     % Payload = iolist_to_binary(mochijson2:encode(Message)),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

% produce_kafka_session_terminated(Message) ->
%     [{_, Topic}] = ets:lookup(topic_table, kafka_session_terminated_topic),
%     % io:format("send to kafka event topic: byte size: ~p~n", [list_to_binary(Topic)]),
%     % Payload = iolist_to_binary(mochijson2:encode(Message)),
%     Payload = jsx:encode(Message),
%     ok = ekaf:produce_async(list_to_binary(Topic), Payload),
%     ok.

timestamp() ->
    {M, S, _} = os:timestamp(),
    M * 1000000 + S.
