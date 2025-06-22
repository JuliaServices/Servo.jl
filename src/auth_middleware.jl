const OKTA_VERIFIER = Ref{OktaJWTVerifier.Verifier}()
const USER = ScopedValue{Union{Auth0User, Nothing}}(nothing)
const REQUEST = ScopedValue{Union{HTTP.Request, Nothing}}(nothing)
const JWTTOKEN = ScopedValue{Union{String, Nothing}}(nothing)

getuser() = USER[]
getrequest() = REQUEST[]
gettoken() = JWTTOKEN[]

function initialize_auth_verifier!()
    @assert haskey(CONFIGS, "okta") && haskey(CONFIGS["okta"], "oauth2") && haskey(CONFIGS["okta"]["oauth2"], "issuer") "Missing required config: okta.oauth2.issuer"
    issuer = CONFIGS["okta"]["oauth2"]["issuer"]
    aud = CONFIGS["okta"]["oauth2"]["audience"]
    OKTA_VERIFIER[] = OktaJWTVerifier.Verifier(issuer; claims_to_validate=Dict("aud" => aud))
    return
end

function auth_middleware(handler)
    return function(req::HTTP.Request)
        req.method == "OPTIONS" && return handler(req)
        auth_header = HTTP.header(req.headers, "Authorization", "")
        auth_header == "" && return HTTP.Response(401, "Unauthorized")
        auth_header = split(auth_header, " ")
        length(auth_header) != 2 && return HTTP.Response(401, "Unauthorized")
        HTTP.ascii_lc_isequal(auth_header[1], "bearer") || return HTTP.Response(401, "Unauthorized")
        jwt = auth_header[2]
        user = nothing
        try
            claims = OktaJWTVerifier.verify_access_token!(OKTA_VERIFIER[], String(jwt)).claims
            user = Auth0User(claims)
        catch e
            @error "Error verifying access token" exception=(e, catch_backtrace())
            return HTTP.Response(401, "Unauthorized")
        end
        try
            return @with USER => user REQUEST => req JWTTOKEN => String(jwt) handler(req)
        catch e
            if e isa BadRequest
                return HTTP.Response(400, e.msg)
            end
            rethrow()
        end
    end
end