/// NetherNet signaling error codes.
pub const ErrorCode = enum(u8) {
    none = 0,

    destination_not_logged_in = 1,
    negotiation_timeout = 2,
    wrong_transport_version = 3,
    failed_to_create_peer_connection = 4,
    ice = 5,
    connect_request = 6,
    connect_response = 7,
    candidate_add = 8,
    inactivity_timeout = 9,

    failed_to_create_offer = 10,
    failed_to_create_answer = 11,
    failed_to_set_local_description = 12,
    failed_to_set_remote_description = 13,

    negotiation_timeout_waiting_for_response = 14,
    negotiation_timeout_waiting_for_accept = 15,
    incoming_connection_ignored = 16,

    signaling_parsing_failure = 17,
    signaling_unknown_error = 18,
    signaling_unicast_message_delivery_failed = 19,
    signaling_broadcast_delivery_failed = 20,
    signaling_message_delivery_failed = 21,
    signaling_turn_auth_failed = 22,
    signaling_fallback_to_best_effort_delivery = 23,
    no_signaling_channel = 24,
    not_logged_in = 25,
    signaling_failed_to_send = 26,

    relay_server_configuration_result_failure = 27,
    relay_server_configuration_result_parsing_error_no_urls = 28,
    relay_server_configuration_result_parsing_error_no_credentials = 29,
    relay_server_configuration_result_parsing_error_no_servers = 30,
    relay_server_configuration_result_parsing_error_no_expiration = 31,

    data_channel_closed = 32,
    internal_error_json_serialization = 33,
    invalid_argument = 34,
    generic_failure = 35,
    failed_to_create_identity_assertion = 36,
    identity_not_allowed = 37,
};
