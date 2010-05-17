
module EventMachineTailTestHelpers
  def abort_after_timeout(seconds)
    EM::Timer.new(seconds) do
      EM.stop_event_loop
      flunk("Timeout (#{seconds} seconds) while running tests. Failing.")
    end
  end

  def finish
    EventMachine.stop_event_loop
  end
end # module EventMachineTailTestHelpers
