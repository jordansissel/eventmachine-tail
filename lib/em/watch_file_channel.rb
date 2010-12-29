

module EventMachine
  def self.watch_file_channel(filename, handler=nil, *args, &block)
    @watch_file_channels ||= {}

    if !@watch_file_channels.include?(filename)
      EventMachine::watch_file(filename, FileWatchChannel,
                               EventMachine::Channel.new) do |fwc|
        @watch_file_channels[filename] = fwc
      end
    end

    if block_given?
      @watch_file_channel[filename].subscribe(&block)
    elsif handler != nil
      instance = handler.new(@watch_file_channel[filename], *args)
      @watch_file_channel[filename].subscribe(&block)
    else
      raise "No handler or block given, not watch file #{filename}. Nothing to do!"
    end
  end # EventMachine::watch_file_channel

  class FileWatchChannel < EventMachine::FileWatch
    attr_reader :channel

    def initialize(channel)
      @channel = channel
    end

    def subscribe(&block)
      @channel.subscribe(&block)
    end

    def unsubscribe(id)
      @channel.unsubscribe(id)
    end

    def file_deleted
      @channel.push(:file_deleted, self)
    end

    def file_modified
      @channel.push(:file_modified, self)
    end

    def file_moved
      @channel.push(:file_moved, self)
    end
  end # class FileWatchChannel
end # module EventMachine
