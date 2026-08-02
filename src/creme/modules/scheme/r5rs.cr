# ===========================================================================
# (scheme r5rs)
# ===========================================================================
#
# (scheme r5rs) is (scheme base)'s whole export surface plus two
# R5RS-compatibility environment constructors. Rather than re-list base's
# names, it imports (scheme base)'s own derived exports (registered just
# before this in install_base_and_write_libraries) and adds its own module.

module Creme::R7RS::R5rsLibrary
  extend self
  include Creme::BuiltinHelpers

  # (null-environment version) — an environment with only the syntactic
  # keywords bound, no procedures. `version` (5, matching R5RS) is
  # accepted but otherwise unused, per R7RS's own description of this
  # procedure existing for R5RS-compatibility purposes.
  @[Creme::SchemeFn("null-environment", min: 0, max: 1)]
  def null_environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    target_env = Env.new
    interp.install_special_forms(target_env)
    SchemeEnvironment.new(target_env)
  end

  # (scheme-report-environment version) — an environment containing the
  # R5RS-report bindings. This implementation doesn't maintain a
  # separate R5RS-vs-R7RS binding set, so, like null-environment, this
  # wraps @base_env — i.e. (builtin base)'s bindings, not any
  # Scheme-defined additions layered on top by (scheme base) (see
  # modules/scheme/base.cr's install_scheme_base_and_write_libraries).
  @[Creme::SchemeFn("scheme-report-environment", min: 0, max: 1)]
  def scheme_report_environment(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeEnvironment.new(interp.base_env)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "r5rs"] do |env|
      base = @libraries[["creme", "builtin", "base"]]
      SchemeLibrary.import_bindings(env, base.exports.map { |external, internal| {external, base, internal} })
      base.exports.keys + register_module(Creme::R7RS::R5rsLibrary, env)
    end
  end
end
