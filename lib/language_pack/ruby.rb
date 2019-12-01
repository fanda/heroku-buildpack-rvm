require "tmpdir"
require "rubygems"
require "language_pack"
require "language_pack/base"

# base Ruby Language Pack. This is for any base ruby app.
class LanguagePack::Ruby < LanguagePack::Base
  LIBYAML_VERSION     = "0.1.4"
  LIBYAML_PATH        = "libyaml-#{LIBYAML_VERSION}"
  BUNDLER_VERSION     = "2.0.2"
  BUNDLER_GEM_PATH    = "bundler-#{BUNDLER_VERSION}"
  NODE_VERSION        = "0.4.7"
  NODE_JS_BINARY_PATH = "node-#{NODE_VERSION}"
  RUBY_PKG_EXTENSION  = "tar.bz2"

  # detects if this is a valid Ruby app
  # @return [Boolean] true if it's a Ruby app
  def self.use?
    File.exist?("Gemfile")
  end

  def name
    "Ruby"
  end

  def default_addons
    add_shared_database_addon
  end

  def default_config_vars
    vars = {
      "LANG"     => "en_US.UTF-8",
      "PATH"     => default_path,
      "GEM_PATH" => slug_vendor_base,
      "GEM_HOME" => "/tmp/gems"
    }
  end

  def default_process_types
    {
      "rake"    => "bundle exec rake",
      "console" => "bundle exec irb"
    }
  end

  def compile
    Dir.chdir(build_path)
    remove_vendor_bundle
    install_ruby
    setup_language_pack_environment
    setup_profiled
    allow_git do
      install_language_pack_gems
      build_bundler
      create_database_yml
      run_assets_precompile_rake_task
    end
  end

private

  # the base PATH environment variable to be used
  # @return [String] the resulting PATH
  def default_path
    "bin:#{slug_vendor_base}/bin:/usr/local/bin:/usr/bin:/bin"
  end

  # the relative path to the bundler directory of gems
  # @return [String] resulting path
  def slug_vendor_base
    # @slug_vendor_base ||= run(%q(ruby -e "require 'rbconfig';puts \"vendor/bundle/#{RUBY_ENGINE}/#{RbConfig::CONFIG['ruby_version']}\"")).chomp
    @slug_vendor_base ||= File.join(build_path, "vendor", "bundle", "ruby", ruby_version.sub(/\d+$/, '0'))
  end

  # the relative path to the vendored ruby directory
  # @return [String] resulting path
  def slug_vendor_ruby
    "vendor/#{ruby_version}"
  end

  # the absolute path of the build ruby to use during the buildpack
  # @return [String] resulting path
  def build_ruby_path
    "/tmp/#{ruby_version}"
  end

  # fetch the ruby version from bundler
  # @return [String, nil] returns the ruby version if detected or nil if none is detected
  def ruby_version
    return @ruby_version if @ruby_version_run

    @ruby_version_run = true

    bootstrap_bundler do |bundler_path|
      #@ruby_version = lockfile_parser.ruby_version.chomp.sub(/p\d+$/, '')
      #puts "RUBY IS #{@ruby_version}"
      ruby_path = File.dirname(`which ruby`)
      old_system_path = "#{ruby_path}:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
      #@ruby_version = run_stdout("env PATH=#{old_system_path}:#{bundler_path}/bin GEM_PATH=#{bundler_path} bundle platform --ruby").chomp
      @ruby_version = run_stdout("GEM_PATH=#{bundler_path} #{bundler_path}/bin/bundle platform --ruby").chomp.sub(/p\d+$/, '')
    end

    if @ruby_version == "No ruby version specified" && ENV['RUBY_VERSION']
      # for backwards compatibility.
      # this will go away in the future
      @ruby_version = ENV['RUBY_VERSION']
      @ruby_version_env_var = true
    elsif @ruby_version == "No ruby version specified"
      @ruby_version = nil
    else
      @ruby_version = @ruby_version.sub('(', '').sub(')', '').split.join('-')
      @ruby_version_env_var = false
    end

    @ruby_version
  end

  # bootstraps bundler so we can pull the ruby version
  def bootstrap_bundler(&block)
    Dir.mktmpdir("bundler-") do |tmpdir|
      Dir.chdir(tmpdir) do
        run("curl #{VENDOR_URL}/#{BUNDLER_GEM_PATH}.tar.gz | tar -xz --strip-components=1")
      end

      yield tmpdir
    end
  end

  # sets up the environment variables for the build process
  def setup_language_pack_environment
    setup_ruby_install_env

    config_vars = default_config_vars.each do |key, value|
      ENV[key] ||= value
    end
    ENV["GEM_HOME"] = slug_vendor_base
    ENV["PATH"]     = "#{ruby_install_binstub_path}:#{config_vars["PATH"]}"
  end

  # sets up the profile.d script for this buildpack
  def setup_profiled
    set_env_default  "GEM_PATH", "$HOME/#{slug_vendor_base}"
    set_env_default  "LANG",     "en_US.UTF-8"
    set_env_override "PATH",     "$HOME/bin:$HOME/#{slug_vendor_base}/bin:$PATH"
  end

  # install the vendored ruby
  # @return [Boolean] true if it installs the vendored ruby and false otherwise
  def install_ruby
    ruby_package_path = '/tmp/ruby'

    topic "Want to use Ruby #{ruby_version} (test: #{`ruby -v`.chomp}, pkg_path: #{ruby_package_path}, slug_path: #{slug_vendor_ruby})"

    FileUtils.mkdir_p(ruby_package_path)
    Dir.chdir(ruby_package_path) do
      puts run("/usr/local/rvm/bin/rvm prepare #{ruby_version}")
    end

    FileUtils.mkdir_p(slug_vendor_ruby)
    Dir.chdir(slug_vendor_ruby) do
      puts run("cat #{ruby_package_path}/#{ruby_version}.#{RUBY_PKG_EXTENSION} | tar -xj --strip-components=1")
    end
    error "Invalid RUBY_VERSION specified: #{ruby_version}" unless $?.success?

    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir["#{slug_vendor_ruby}/bin/*"].each do |bin|
      run("ln -s ../#{bin} #{bin_dir}")
    end

    topic "Using Ruby version: #{ruby_version} (test: #{`ruby -v`})"

    true
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_binstub_path
    #puts "ruby_install_binstub_path: #{slug_vendor_ruby}/bin"
    @ruby_install_binstub_path ||= "#{slug_vendor_ruby}/bin"
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_libstub_path
    #puts "ruby_install_libstub_path: #{slug_vendor_ruby}/lib"
    @ruby_install_libstub_path ||= "#{slug_vendor_ruby}/lib"
  end

  # setup the environment so we can use the vendored ruby
  def setup_ruby_install_env
    #puts "setup_ruby_install_env: #{ruby_install_binstub_path}"
    ENV["PATH"] = "#{ruby_install_binstub_path}:#{ENV["PATH"]}"

    #puts "setup_ruby_install_env: #{ruby_install_libstub_path}"
    ENV["LD_LIBRARY_PATH"] = "#{File.expand_path(ruby_install_libstub_path)}:#{ENV["LD_LIBRARY_PATH"]}"
  end

  # list of default gems to vendor into the slug
  # @return [Array] resulting list of gems
  def gems
    [BUNDLER_GEM_PATH]
  end

  # installs vendored gems into the slug
  def install_language_pack_gems
    FileUtils.mkdir_p(slug_vendor_base)
    Dir.chdir(slug_vendor_base) do |dir|
      [BUNDLER_GEM_PATH].each do |gem|
        puts run("curl #{VENDOR_URL}/#{gem}.tar.gz | tar -xz --strip-components=1")
      end
      Dir["bin/*"].each {|path| run("chmod 755 #{path}") }
    end
  end

  # install libyaml into the LP to be referenced for psych compilation
  # @param [String] tmpdir to store the libyaml files
  def install_libyaml(dir)
    FileUtils.mkdir_p dir
    Dir.chdir(dir) do |dir|
      run("curl #{VENDOR_URL}/#{LIBYAML_PATH}.tgz -s -o - | tar xzf -")
    end
  end

  # remove `vendor/bundle` that comes from the git repo
  # in case there are native ext.
  # users should be using `bundle pack` instead.
  # https://github.com/heroku/heroku-buildpack-ruby/issues/21
  def remove_vendor_bundle
    if File.exists?("vendor/bundle")
      topic "WARNING:  Removing `vendor/bundle`."
      puts  "Checking in `vendor/bundle` is not supported. Please remove this directory"
      puts  "and add it to your .gitignore. To vendor your gems with Bundler, use"
      puts  "`bundle pack` instead."
      FileUtils.rm_rf("vendor/bundle")
    end
  end

  # runs bundler to install the dependencies
  def build_bundler
    log("bundle") do
      bundle_without = ENV["BUNDLE_WITHOUT"] || "development:test"
      bundle_command = "#{slug_vendor_base}/bin/bundle install --without #{bundle_without} --path vendor/bundle --binstubs bin/"

      unless File.exist?("Gemfile.lock")
        error "Gemfile.lock is required. Please run \"bundle install\" locally\nand commit your Gemfile.lock."
      end

      # using --deployment is preferred if we can
      bundle_command += " --deployment"
      cache_load ".bundle"

      version = run("env #{slug_vendor_base}/bin/bundle version").strip
      topic("Installing dependencies using bundler #{version}")

      cache_load "vendor/bundle"

      bundler_output = ""
      Dir.mktmpdir("libyaml-") do |tmpdir|
        libyaml_dir = "#{tmpdir}/#{LIBYAML_PATH}"
        install_libyaml(libyaml_dir)

        # need to setup compile environment for the psych gem
        yaml_include   = File.expand_path("#{libyaml_dir}/include")
        yaml_lib       = File.expand_path("#{libyaml_dir}/lib")
        pwd            = run("pwd").chomp
        # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
        # codon since it uses bundler.
        env_vars       = "env BUNDLE_GEMFILE=#{pwd}/Gemfile BUNDLE_CONFIG=#{pwd}/.bundle/config CPATH=#{yaml_include}:$CPATH CPPATH=#{yaml_include}:$CPPATH LIBRARY_PATH=#{yaml_lib}:$LIBRARY_PATH"
        puts "Running: #{bundle_command}"
        bundler_output << pipe("#{env_vars} #{bundle_command} --no-clean 2>&1")

      end

      if $?.success?
        log "bundle", :status => "success"
        puts "Cleaning up the bundler cache."
        run "bundle clean"
        cache_store ".bundle"
        cache_store "vendor/bundle"

        # Keep gem cache out of the slug
        FileUtils.rm_rf("#{slug_vendor_base}/cache")
      else
        log "bundle", :status => "failure"
        error_message = "Failed to install gems via Bundler."
        if bundler_output.match(/Installing sqlite3 \([\w.]+\) with native extensions\s+Gem::Installer::ExtensionBuildError: ERROR: Failed to build gem native extension./)
          error_message += <<ERROR


Detected sqlite3 gem which is not supported on Heroku.
http://devcenter.heroku.com/articles/how-do-i-use-sqlite3-for-development
ERROR
        end

        error error_message
      end
    end
  end

  # add bundler to the load path
  # @note it sets a flag, so the path can only be loaded once
  def add_bundler_to_load_path
    return if @bundler_loadpath
    $: << File.expand_path(Dir["#{slug_vendor_base}/lib"].first)
    @bundler_loadpath = true
  end

  # detects if a gem is in the bundle.
  # @param [String] name of the gem in question
  # @return [String, nil] if it finds the gem, it will return the line from bundle show or nil if nothing is found.
  def gem_is_bundled?(gem)
    @bundler_gems ||= lockfile_parser.specs.map(&:name)
    @bundler_gems.include?(gem)
  end

  # setup the lockfile parser
  # @return [Bundler::LockfileParser] a Bundler::LockfileParser
  def lockfile_parser
    add_bundler_to_load_path
    require "bundler"
    @lockfile_parser ||= Bundler::LockfileParser.new(File.read("Gemfile.lock"))
  end

  # detects if a rake task is defined in the app
  # @param [String] the task in question
  # @return [Boolean] true if the rake task is defined in the app
  def rake_task_defined?(task)
    run("env PATH=$PATH bundle exec rake #{task} --dry-run") && $?.success?
  end

  # executes the block with GIT_DIR environment variable removed since it can mess with the current working directory git thinks it's in
  # @param [block] block to be executed in the GIT_DIR free context
  def allow_git(&blk)
    git_dir = ENV.delete("GIT_DIR") # can mess with bundler
    blk.call
    ENV["GIT_DIR"] = git_dir
  end

  # decides if we need to enable the shared database addon
  # @return [Array] the database addon if the pg gem is detected or an empty Array if it isn't.
  def add_shared_database_addon
    gem_is_bundled?("pg") ? ['shared-database:5mb'] : []
  end

  # decides if we need to install the node.js binary
  # @note execjs will blow up if no JS RUNTIME is detected and is loaded.
  # @return [Array] the node.js binary path if we need it or an empty Array
  def add_node_js_binary
    gem_is_bundled?('execjs') ? [NODE_JS_BINARY_PATH] : []
  end

  def run_assets_precompile_rake_task
    if rake_task_defined?("assets:precompile")
      require 'benchmark'

      topic "Running: rake assets:precompile"
      time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake assets:precompile 2>&1") }
      if $?.success?
        puts "Asset precompilation completed (#{"%.2f" % time}s)"
      end
    end
  end

  # writes ERB based database.yml for Rails. The database.yml uses the DATABASE_URL from the environment during runtime.
  def create_database_yml
    log("create_database_yml") do
      return unless File.directory?("config")
      topic("Writing config/database.yml to read from DATABASE_URL")
      File.open("config/database.yml", "w") do |file|
        file.puts <<-DATABASE_YML
<%

require 'cgi'
require 'uri'

begin
  uri = URI.parse(ENV["DATABASE_URL"])
rescue URI::InvalidURIError
  raise "Invalid DATABASE_URL"
end

raise "No RACK_ENV or RAILS_ENV found" unless ENV["RAILS_ENV"] || ENV["RACK_ENV"]

def attribute(name, value, force_string = false)
  if value
    value_string =
      if force_string
        '"' + value + '"'
      else
        value
      end
    "\#{name}: \#{value_string}"
  else
    ""
  end
end

adapter = uri.scheme
adapter = "postgresql" if adapter == "postgres"

database = (uri.path || "").split("/")[1]

username = uri.user
password = uri.password

host = uri.host
port = uri.port

params = CGI.parse(uri.query || "")

%>

<%= ENV["RAILS_ENV"] || ENV["RACK_ENV"] %>:
  <%= attribute "adapter",  adapter %>
  <%= attribute "database", database %>
  <%= attribute "username", username %>
  <%= attribute "password", password, true %>
  <%= attribute "host",     host %>
  <%= attribute "port",     port %>

<% params.each do |key, value| %>
  <%= key %>: <%= value.first %>
<% end %>
        DATABASE_YML
      end
    end
  end

end
