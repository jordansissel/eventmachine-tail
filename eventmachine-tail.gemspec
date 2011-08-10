Gem::Specification.new do |spec|
  files = []
  dirs = %w{lib samples test bin}
  dirs.each do |dir|
    files += Dir["#{dir}/**/*"]
  end

  spec.name = "eventmachine-tail"
  spec.version = "0.6.2"
  spec.summary = "eventmachine tail - a file tail implementation with glob support"
  spec.description = "Add file 'tail' implemented with EventMachine. Also includes a 'glob watch' class for watching a directory pattern for new matches, like /var/log/*.log"
  spec.add_dependency("eventmachine")
  spec.files = files
  spec.require_paths << "lib"
  spec.bindir = "bin"
  spec.executables << "rtail"

  # Add 'emtail' since 'rtail' conflicts with gem 'file-tail' rtail
  spec.executables << "emtail"

  spec.author = "Jordan Sissel"
  spec.email = "jls@semicomplete.com"
  spec.homepage = "http://code.google.com/p/semicomplete/wiki/EventMachineTail"
end

