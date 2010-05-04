Gem::Specification.new do |spec|
  files = []
  dirs = %w{lib samples}
  dirs.each do |dir|
    files += Dir["#{dir}/**/*"]
  end

  svnrev = %x{svn info}.split("\n").grep(/Revision:/).first.split(" ").last.to_i
  spec.name = "eventmachine-tail"
  spec.version = "0.1.#{svnrev}"
  spec.summary = "eventmachine tail - a file tail implementation"
  spec.description = "Add file 'tail' implemented with EventMachine"
  spec.add_dependency("eventmachine")
  spec.files = files
  spec.require_paths << "lib"
  spec.author = "Jordan Sissel"
  spec.email = "jls@semicomplete.com"
  spec.homepage = "http://code.google.com/p/semicomplete/wiki/EventMachineTail"
end

