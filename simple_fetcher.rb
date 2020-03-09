require 'rexml/document'
require 'net/http'
require 'awesome_print'
require 'json'
require 'parallel'
require 'socket'
require 'erb'
require 'pathname'
require 'logger'

module SimpleFetcher
  class Platform
    def self.darwin?
      RUBY_PLATFORM =~ /darwin/
    end

    def self.windows?
      # SO: What is the correct way to detect if ruby is running on Windows?,
      # cf. https://stackoverflow.com/a/21468976/2592915
      Gem.win_platform? || RUBY_PLATFORM =~ /mswin|cygwin|mingw/
    end
  end

  class NugetPackageManager
    def initialize(options = {})
      @project_path = options[:project_path]
      @log_directory = Pathname.new(options[:log_directory] || @project_path).expand_path
      @log_file_name = package_management_command&.gsub(/\s/, '_')&.gsub(%r{/}, '') || 'simple_fetcher'
      @logger = options[:logger] || SimpleFetcher::Logger.new(@log_directory, @log_file_name)
      @api_url = ENV.fetch('NUGET_API_URL', 'https://api.nuget.org')
      @frontend_url = ENV.fetch('NUGET_FRONTEND_URL', @api_url.sub(/api/,'www'))
    end

    class Assembly
      def initialize(path, api_url, frontend_url)
        @path = path
        @api_url = api_url
        @frontend_url = frontend_url
      end

      def dependencies
        xml = REXML::Document.new(File.read(@path))
        packages = REXML::XPath.match(xml, '//package')
        Parallel.map(packages) do |p|
          attrs = p.attributes
          Dependency.new(attrs['id'], attrs['version'], @path, @logger, @api_url, @frontend_url)
        end
      end
    end

    attr_reader :dependencies

    def files
      Dir.glob(@project_path.join('**', 'packages.config'), File::FNM_DOTMATCH).map do |d|
        path = Pathname.new(d).expand_path
        Assembly.new(path, @api_url, @frontend_url)
      end
    end

    def dependencies
      files.flat_map(&:dependencies)
    end

    def package_management_command
      return 'nuget' if Platform.windows?
      'mono /usr/local/bin/nuget.exe'
    end

    def fetch_sources_command
      "#{package_management_command} sources -Format short -NonInteractive -ForceEnglishOutput"
    end

    def fetch_source
      fetch_cmd = "#{fetch_sources_command}"
      _stdout, stderr, status = Dir.chdir(project_path) { Cmd.run(prep_cmd) }

      return if status.success?

      log_errors stderr
      raise "Prepare command '#{prep_cmd}' failed" unless @prepare_no_fail
    end

    class Dependency
      def initialize(name, version, assembly, logger, api_url, frontend_url)
        @file = assembly
        @api_url = api_url
        @frontend_url = frontend_url
        @version = version
        @name = name
        @logger = logger
        fetch_license_url(name, version)
      end

      attr_reader :file, :version, :name, :license_url, :project_url, :description

      def fetch_license_url(name, version)
        begin
          leaf_uri = URI(File.join(@api_url,'v3','registration3',name.downcase,"#{semantic_version_2(version)}.json"))
          leaf_res = Net::HTTP.get_response(leaf_uri)
          catalog_entry = URI(JSON.parse(leaf_res.body)['catalogEntry'])
          catalog_res = Net::HTTP.get_response(catalog_entry)
          @license_url = JSON.parse(catalog_res.body)['licenseUrl']
          @description = JSON.parse(catalog_res.body)['description']
          @project_url = File.join(@frontend_url,'packages',name,version)
        rescue => e
          @license_url = 'unknown'
          @description = ''
          @project_url = ''
          # @logger.log_errors 'fetch_license_url', e
        end
      end

      def semantic_version_2(version)
        v = version.split('.')
        if v[-1].to_i == 0 && v.length == 4
          v[0..-2].join('.')
        else
          v.join('.')
        end
      end
    end
  end
  class FnciReport
    TEMPLATE= <<-XML
    <?xml version='1.0' encoding='utf-8'?>
    <palamidaWorkspace exportDate="<%= Time.now.strftime('%Y-%m-%d %H:%M:%S') %>" exportScriptCompatibleWithPalamidaVersion="6.1" exportScriptVersion="" exportTimestampGMT="<%= Time.now.to_i %>" serverName="<%= hostname %>">
      <groups><%- sorted_dependencies.each do |dependency| %>
        <group name="<%= dependency.name %> <%= dependency.version %>">
          <id>-1</id>
          <owner><%= owner %></owner>
          <title />
          <statusId>2</statusId>
          <priorityId>6</priorityId>
          <isDisclosed />
          <isIgnored />
          <component />
          <componentVersion />
          <selectedLicense />
          <possibleLicenses />
          <distributionLicenseText>License can be found at the website: <%= dependency.license_url %></distributionLicenseText>
          <extNotes />
          <intNotes />
          <isEngineeringActionRequired />
          <isLegalActionRequired />
          <auditorReviewNotes />
          <detectionNotes />
          <fieldOfUse />
          <includeInThirdPartyNotices />
          <isModified />
          <noticeCopyrightStatements />
          <noticeLicenseText />
          <noticeLicenseURL />
          <noticeOtherFlowThroughNotices />
          <noticeTitle />
          <noticeTitleURL />
          <isShipped />
          <isSourceDistributionRequired />
          <thirdPartySourceURL />
          <url><%= dependency.project_url %></url>
          <description><%= dependency.description %></description>
          <publishedBy />
          <isPublished />
          <publishedDate />
          <isRemediation />
          <groupMetadata />
          <isSystemGenerated>false</isSystemGenerated>
          <systemGeneratedGroupId />
          <updateDate />
        </group><%- end %>
      </groups>
      <files><%- grouped_dependencies.each do |file, groups| %>
        <file fullPath="<%= file.to_s %>">
          <fileName><%= File.basename(file.to_s) %></fileName>
          <md5 />
          <groups>
            <% groups.each do |group| %>
            <group><%= group.name %></group>
            <%- end %>
          </groups>
        </file><%- end %>
      </files>
    </palamidaWorkspace>
    XML

    attr_reader :dependencies, :owner, :hostname

    def to_s()
      template = ERB.new(TEMPLATE, nil, '-')
      template.result(binding)
    end

    def initialize(options = {})
      @project_path = options[:project_path]
      @owner = options[:owner]
      @log_directory = Pathname.new(options[:log_directory] || @project_path).expand_path
      @log_file_name = 'simple_fetcher'
      @logger = SimpleFetcher::Logger.new(@log_directory, @log_file_name)
      @dependencies = SimpleFetcher::NugetPackageManager.new(
        project_path: @project_path,
        log_directory: @log_directory,
        log_file_name: @log_file_name,
        logger: @logger
      ).dependencies
      @hostname = Socket.gethostname
    end

    def sorted_dependencies
      dependencies
        .uniq { |dep| dep.name + dep.version }
        .sort_by { |dep| dep.name }
    end

    def grouped_dependencies
      dependencies
        .group_by { |dep| dep.file }
        .sort_by { |_, group| -group.size }
    end
  end

  class Logger
    MODE_QUIET = :quiet
    MODE_INFO = :info
    MODE_DEBUG = :debug

    attr_reader :mode

    def initialize(log_directory, log_file_name, mode = nil)
      @system_logger = ::Logger.new(STDOUT)
      @system_logger.formatter = proc do |_, _, _, msg|
        "#{msg}\n"
      end
      @log_directory = log_directory
      @log_file_name = log_file_name

      self.mode = mode || MODE_INFO
    end

    [MODE_INFO, MODE_DEBUG].each do |level|
      define_method level do |prefix, string, options = {}|
        msg = format('%s: %s', prefix, colorize(string, options[:color]))
        log(msg, level)
      end
    end

    def log_errors(command, stderr)
      @system_logger.info command, 'did not succeed.', color: :red
      @system_logger.info command, stderr, color: :red
      log_to_file(command, stderr)
    end

    def log_to_file(command, contents)
      FileUtils.mkdir_p @log_directory

      log_file = File.join(@log_directory, "#{@log_file_name || 'errors'}.log")

      File.open(log_file, 'w') do |f|
        f.write("\"#{command}\" failed with:\n")
        f.write("#{contents}\n\n")
      end
    end

    private

    attr_reader :system_logger

    def colorize(string, color)
      case color
      when :red
        "\e[31m#{string}\e[0m"
      when :green
        "\e[32m#{string}\e[0m"
      else
        string
      end
    end

    def mode=(verbose)
      @mode = verbose

      return if quiet?

      level = @mode.equal?(MODE_DEBUG) ? ::Logger::DEBUG : ::Logger::INFO
      @system_logger.level = level
    end

    def log(msg, method)
      return if quiet?

      @system_logger.send(method, msg)
    end

    def debug?
      @mode.equal?(MODE_DEBUG)
    end

    def quiet?
      @mode.equal?(MODE_QUIET)
    end
  end
end

File.write("nuget_groups_for_import.xml", SimpleFetcher::FnciReport.new(project_path: Pathname.new(ARGV[0]).expand_path, owner: 'katherinet').to_s)
