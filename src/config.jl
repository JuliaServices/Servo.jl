const CONFIG = Figgy.Store()

# the only environment variables loaded into config by default; everything else
# comes from explicit sources (program args, config files, `configs` kwarg)
const ENV_MAPPINGS = ("PROFILE" => "profile", "PORT" => "port", "VERSION" => "version")

"""
    Servo.config(key, default=nothing)

Look up a configuration value loaded by `Servo.run!`/`Servo.loadconfig!`. Dotted
keys traverse nested sections: `Servo.config("database.host")` finds `host` in the
`[database]` table of a config file.
"""
function config(key::AbstractString, default=nothing)
    parts = split(key, '.')
    val = get(CONFIG, String(first(parts)), nothing)
    for i in 2:length(parts)
        # nested sections come from config-file tables (TOML etc.), parsed as Dict{String, Any}
        val isa Dict{String, Any} || return default
        val = get(val, String(parts[i]), nothing)
    end
    return val === nothing ? default : val
end

"""current config profile ("local" unless configured otherwise)"""
profile() = config("profile", "local")::String

"""
    Servo.loadconfig!(; profile="", configdir=nothing, configs=Dict(), log=!isinteractive()) -> profile

Layer configuration into `Servo.CONFIG`. From weakest to strongest:

1. `configdir/config.toml` (base config, all profiles)
2. environment variables `PROFILE`, `PORT`, `VERSION`
3. program arguments (`--key=value`)
4. `configs` (programmatic overrides)
5. the explicit `profile` argument, if given
6. `configdir/config-<profile>.toml` (profile config, checked in)
7. `configdir/.config-<profile>.toml` (profile secrets, gitignored)

Returns the resolved profile name.
"""
function loadconfig!(; profile::AbstractString="", configdir::Union{AbstractString, Nothing}=nothing,
                       configs=Dict{String, Any}(), log::Bool=!isinteractive())
    # one concretely-typed source per load! call (keeps Figgy's source handling
    # statically dispatched for juliac/trim); later calls override earlier ones,
    # so load weakest -> strongest
    if configdir !== nothing
        f = joinpath(configdir, "config.toml")
        isfile(f) && Figgy.load!(CONFIG, Figgy.TomlObject(f); log)
    end
    Figgy.load!(CONFIG, Figgy.kmap(Figgy.EnvironmentVariables(), ENV_MAPPINGS...; select=true); log)
    Figgy.load!(CONFIG, Figgy.ProgramArguments(); log)
    isempty(configs) || Figgy.load!(CONFIG, configs; name="configs", log)
    isempty(profile) || Figgy.load!(CONFIG, Dict("profile" => String(profile)); name="profile argument", log)
    prof = Servo.profile()
    if configdir !== nothing
        for fname in ("config-$prof.toml", ".config-$prof.toml")
            f = joinpath(configdir, fname)
            isfile(f) && Figgy.load!(CONFIG, Figgy.TomlObject(f); log)
        end
    end
    return prof
end
