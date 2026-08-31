using System.Security.Cryptography;
using System.Text.Json;
using NetherNet.Internal;

namespace NetherNet;

public sealed record Identity
{
    public required ECDsa PrivateKey { get; init; }
    public required string Token { get; init; }
    public required string Domain { get; init; }

    public static Identity GenerateServer(ECDsa privateKey, string domain)
    {
        ArgumentNullException.ThrowIfNull(privateKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(domain);

        var encodedKey = Convert.ToBase64String(privateKey.ExportSubjectPublicKeyInfo());
        var now = DateTimeOffset.UtcNow;
        var claims = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["exp"] = now.AddMinutes(1).ToUnixTimeSeconds(),
            ["iat"] = now.ToUnixTimeSeconds(),
            ["cpk"] = encodedKey
        });
        var token = Jose.JWT.EncodeBytes(
            claims,
            privateKey,
            Jose.JwsAlgorithm.ES384,
            extraHeaders: new Dictionary<string, object> { ["x5u"] = encodedKey });

        return new Identity
        {
            PrivateKey = privateKey,
            Token = token,
            Domain = domain
        };
    }

    internal IdentityData CreateAssertion(IReadOnlyList<DtlsFingerprint> fingerprints)
    {
        var payload = CreateFingerprintPayload(fingerprints);
        string signature;
        lock (PrivateKey)
        {
            signature = Jose.JWT.EncodeBytes(
                payload,
                PrivateKey,
                Jose.JwsAlgorithm.ES384,
                extraHeaders: new Dictionary<string, object>(),
                options: new Jose.JwtOptions { DetachPayload = true });
        }

        return new IdentityData(
            new IdentityAssertion(signature, Token),
            new IdentityProvider(Domain, "default"));
    }

    internal static ECDsa ClaimPublicKey(string token, bool verifySelfSigned)
    {
        var segments = token.Split('.');
        if (segments.Length != 3)
        {
            throw new CryptographicException("Identity token is not a compact JWT.");
        }

        using var header = JsonDocument.Parse(Base64Url.Decode(segments[0]));
        var algorithm = header.RootElement.GetProperty("alg").GetString();
        if (algorithm is not ("ES384" or "RS256"))
        {
            throw new CryptographicException($"Unsupported JWT algorithm {algorithm}.");
        }

        using var claims = JsonDocument.Parse(Base64Url.Decode(segments[1]));
        ValidateTimeClaims(claims.RootElement);
        if (!claims.RootElement.TryGetProperty("cpk", out var claim))
        {
            throw new CryptographicException("Identity token has no cpk claim.");
        }

        var key = ParsePublicKey(claim);
        if (!verifySelfSigned)
        {
            return key;
        }

        try
        {
            if (algorithm != "ES384")
            {
                throw new CryptographicException("A self-signed identity token must use ES384.");
            }

            _ = Jose.JWT.VerifyBytes(token, key, Jose.JwsAlgorithm.ES384);
            return key;
        }
        catch (Exception exception) when (exception is Jose.JoseException or CryptographicException)
        {
            key.Dispose();
            throw new CryptographicException("Identity token signature verification failed.", exception);
        }
    }

    internal static byte[] CreateFingerprintPayload(IReadOnlyList<DtlsFingerprint> fingerprints)
    {
        using var stream = new MemoryStream();
        using var writer = new Utf8JsonWriter(stream);
        writer.WriteStartObject();
        writer.WritePropertyName("fingerprint");
        writer.WriteStartArray();
        foreach (var fingerprint in fingerprints)
        {
            writer.WriteStartObject();
            writer.WriteString("algorithm", fingerprint.Algorithm);
            writer.WriteString("digest", fingerprint.Value);
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
        writer.WriteEndObject();
        writer.Flush();
        return stream.ToArray();
    }

    private static void ValidateTimeClaims(JsonElement claims)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        const long leewaySeconds = 60;

        if (!claims.TryGetProperty("exp", out var expiration) ||
            expiration.GetInt64() < now - leewaySeconds)
        {
            throw new CryptographicException("Identity token is expired or has no expiration.");
        }
        if (claims.TryGetProperty("nbf", out var notBefore) &&
            notBefore.GetInt64() > now + leewaySeconds)
        {
            throw new CryptographicException("Identity token is not valid yet.");
        }
        if (claims.TryGetProperty("iat", out var issuedAt) &&
            issuedAt.GetInt64() > now + leewaySeconds)
        {
            throw new CryptographicException("Identity token was issued in the future.");
        }
    }

    private static ECDsa ParsePublicKey(JsonElement claim)
    {
        if (claim.ValueKind == JsonValueKind.String)
        {
            var key = ECDsa.Create();
            try
            {
                key.ImportSubjectPublicKeyInfo(
                    Convert.FromBase64String(claim.GetString()!),
                    out _);
                return key;
            }
            catch
            {
                key.Dispose();
                throw;
            }
        }

        if (claim.ValueKind != JsonValueKind.Object)
        {
            throw new CryptographicException(
                "The cpk claim must be a base64 PKIX string or EC JWK object.");
        }
        if (claim.GetProperty("kty").GetString() != "EC")
        {
            throw new CryptographicException("The cpk JWK is not an EC key.");
        }

        var curve = claim.GetProperty("crv").GetString() switch
        {
            "P-384" => ECCurve.NamedCurves.nistP384,
            "P-256" => ECCurve.NamedCurves.nistP256,
            "P-521" => ECCurve.NamedCurves.nistP521,
            var value => throw new CryptographicException($"Unsupported EC curve {value}.")
        };
        return ECDsa.Create(new ECParameters
        {
            Curve = curve,
            Q = new ECPoint
            {
                X = Base64Url.Decode(claim.GetProperty("x").GetString()!),
                Y = Base64Url.Decode(claim.GetProperty("y").GetString()!)
            }
        });
    }
}
