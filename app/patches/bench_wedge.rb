# frozen_string_literal: true

# The Track C wedged state (mirrors odoshi's test/fixtures/flaky_http_server
# pattern, in-app): after POST /bench/wedge, /up answers 503 while the
# process stays alive and every other route keeps working. The flag is
# process-local memory — NOT a file — so restarting the process cures it,
# exactly like a real wedged child (stuck threadpool, poisoned cache, ...).
# PID-aliveness supervision cannot see this state; that is the point.
class BenchWedge
  class << self
    attr_accessor :wedged
  end
  self.wedged = false

  def initialize(app)
    @app = app
  end

  def call(env)
    case [env["REQUEST_METHOD"], env["PATH_INFO"]]
    in ["POST", "/bench/wedge"]
      self.class.wedged = true
      [200, { "content-type" => "text/plain" }, ["wedged pid=#{Process.pid}\n"]]
    in ["POST", "/bench/unwedge"]
      self.class.wedged = false
      [200, { "content-type" => "text/plain" }, ["unwedged\n"]]
    in [_, "/up"] if self.class.wedged
      [503, { "content-type" => "text/plain" }, ["wedged\n"]]
    else
      @app.call(env)
    end
  end
end
