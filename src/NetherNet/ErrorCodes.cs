namespace NetherNet;

public static class ErrorCodes
{
    public const int None = 0;
    public const int DestinationNotLoggedIn = 1;
    public const int NegotiationTimeout = 2;
    public const int WrongTransportVersion = 3;
    public const int FailedToCreatePeerConnection = 4;
    public const int Ice = 5;
    public const int ConnectRequest = 6;
    public const int ConnectResponse = 7;
    public const int CandidateAdd = 8;
    public const int InactivityTimeout = 9;
    public const int FailedToCreateOffer = 10;
    public const int FailedToCreateAnswer = 11;
    public const int FailedToSetLocalDescription = 12;
    public const int FailedToSetRemoteDescription = 13;
    public const int NegotiationTimeoutWaitingForResponse = 14;
    public const int NegotiationTimeoutWaitingForAccept = 15;
    public const int IncomingConnectionIgnored = 16;
    public const int SignalingParsingFailure = 17;
    public const int SignalingUnknownError = 18;
    public const int SignalingUnicastMessageDeliveryFailed = 19;
    public const int SignalingBroadcastDeliveryFailed = 20;
    public const int SignalingMessageDeliveryFailed = 21;
    public const int SignalingTurnAuthFailed = 22;
    public const int SignalingFallbackToBestEffortDelivery = 23;
    public const int NoSignalingChannel = 24;
    public const int NotLoggedIn = 25;
    public const int SignalingFailedToSend = 26;
    public const int RelayServerConfigurationResultFailure = 27;
    public const int RelayServerConfigurationResultParsingErrorNoUrls = 28;
    public const int RelayServerConfigurationResultParsingErrorNoCredentials = 29;
    public const int RelayServerConfigurationResultParsingErrorNoServers = 30;
    public const int RelayServerConfigurationResultParsingErrorNoExpiration = 31;
    public const int DataChannelClosed = 32;
    public const int InternalErrorJsonSerialization = 33;
    public const int InvalidArgument = 34;
    public const int GenericFailure = 35;
    public const int FailedToCreateIdentityAssertion = 36;
    public const int IdentityNotAllowed = 37;
}
