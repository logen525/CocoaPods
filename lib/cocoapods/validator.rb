module Pod

  # Validates a Specification.
  #
  # Extends the Linter from the Core to add additional which require the
  # LocalPod and the Installer.
  #
  # In detail it checks that the file patterns defined by the user match
  # actually do match at least a file and that the Pod builds, by installing
  # it without integration and building the project with xcodebuild.
  #
  class Validator

    include Config::Mixin

    # @param  [Specification, Pathname, String] spec_or_path
    #         the Specification or the path of the `podspec` file to lint.
    #
    def initialize(spec_or_path)
      @linter = Specification::Linter.new(spec_or_path)
    end

    # @return [Specification] the specification to lint.
    #
    def spec
      @linter.spec
    end

    # @return [Pathname] the path of the `podspec` file where {#spec} is
    #         defined.
    #
    def file
      @linter.file
    end

    # @return [Specification::Linter] the linter instance from CocoaPods
    #         Core.
    #
    attr_reader :linter

    # Lints the specification adding a {Specification::Linter::Result} for any
    # failed check to the {#results} list.
    #
    # @note   This method shows immediately which pod is being processed and
    #         overrides the printed line once the result is known.
    #
    # @return [Bool] whether the specification passed validation.
    #
    def validate
      @results  = []
      print " -> #{spec.name}\r" unless config.silent?
      $stdout.flush
      perform_linting
      check_repo_path if repo_path
      perform_extensive_analysis unless quick

      UI.puts " -> ".send(result_color) << spec.name
      print_results
      validated?
    end

    def print_results
      results.each do |result|
        if result.platforms == [:ios]
          platform_message = "[iOS] "
        elsif result.platforms == [:osx]
          platform_message = "[OSX] "
        end

      case result.type
        when :error, :deprecation
          type = "ERROR"
        when :warning
          type = "WARN"
        when :note
          type = "NOTE"
        else
          raise "#{result.type}"
        end

        UI.puts "    - #{type.ljust(5)} | #{platform_message}#{result.message}"
      end
      UI.puts
    end

    #-----------------------------------------------------------------------#

    # @!group Configuration

    # @return [Pathname] whether the validation should be performed against a repo.
    #
    attr_accessor :repo_path

    # @return [Bool] whether the validation should skip the checks that
    #         requires the download or the build of the library.
    #
    attr_accessor :quick

    # @return [Bool] whether the linter should not clean up temporary files
    #         for inspection.
    #
    attr_accessor :no_clean

    # @return [Bool] whether the validation should be performed against the root of
    #   the podspec instead to its original source. Uses the `:local` option
    #   of the Podfile.
    #
    attr_writer :local
    def local?; @local; end

    #
    #
    attr_accessor :only_errors

    #-----------------------------------------------------------------------#

    # !@group Lint results

    #
    #
    attr_reader :results

    # @return [Boolean]
    #
    def validated?
      return false if result_type == :error
      return false if result_type == :warnings && !only_errors
      return true
    end

    # @return [Symbol]
    #
    def result_type
      types = results.map(&:type).uniq
      if types.include?(:error)      then :error
      elsif types.include?(:warning) then :warning
      else :note
      end
    end

    # @return [Symbol]
    #
    def result_color
      case result_type
      when :error
        color = :red
      when :warning
        color = :yellow
      else
        color = :green
      end
    end

    # @return [Pathname] the temporary directory used by the linter.
    #
    def validation_dir
      Pathname.new('/tmp/CocoaPods/Lint')
    end

    #-----------------------------------------------------------------------#

    private

    # !@group Lint steps

    #
    #
    def perform_linting
      linter.lint
      @results.concat(linter.results)
    end

    #
    #
    def check_repo_path
      expected_path = "#{spec.name}/#{spec.version}/#{spec.name}.podspec"
      path = file.relative_path_from(repo_path).to_s
      unless path == expected_path
        error "Incorrect path, the path is `#{file}` and should be `#{expected_path}`"
      end
    end

    #
    #
    def perform_extensive_analysis
      spec.available_platforms.each do |platform|
        UI.message "\n\n#{spec} - Analyzing on #{platform} platform.".green.reversed
        @current_platform = platform
        spec.activate_platform(platform)
        setup_validation_environment
        install_pod
        build_pod
        check_file_patterns
        tear_down_validation_environment
      end
    end

    attr_accessor :current_platform

    def setup_validation_environment
      validation_dir.rmtree if validation_dir.exist?
      validation_dir.mkpath
      @original_config = Config.instance.clone
      config.project_root      = validation_dir
      config.project_pods_root = validation_dir + 'Pods'
      config.silent            = !config.verbose
      config.integrate_targets = false
      config.generate_docs     = false
      config.skip_repo_update  = true
    end

    def tear_down_validation_environment
      # TODO
      validation_dir.rmtree unless no_clean
      Config.instance = @original_config
    end

    # It creates a podfile in memory and builds a library containing
    # the pod for all available platforms with xcodebuild.
    #
    def install_pod
      podfile = podfile_from_spec(current_platform)
      sandbox = Sandbox.new(config.project_pods_root)
      installer = Installer.new(sandbox, podfile)
      installer.install!
      @pod = installer.local_pods.find { |pod| pod.top_specification == spec }
      config.silent
    end

    # Performs platform specific analysis.
    # It requires to download the source at each iteration
    #
    # @note Treat xcodebuild warnings as notes because the spec maintainer
    #       might not be the author of the library
    #
    def build_pod
      if `which xcodebuild`.strip.empty?
        UI.warn "Skipping compilation with `xcodebuild' because it can't be found.\n".yellow
      else
        UI.message "\nBuilding with xcodebuild.\n".yellow do
          messages      = []
          output        = Dir.chdir(config.project_pods_root) { `xcodebuild clean build 2>&1` }
          UI.puts output
          parsed_output  = parse_xcodebuild_output(output)
          parsed_output.each do |message|
            if message.include?('error: ')
              error "XCODEBUILD #{message}"
            else
              note "XCODEBUILD #{message}"
            end
          end
        end
      end
    end

    # It checks that every file pattern specified in a spec yields
    # at least one file. It requires the pods to be already present
    # in the current working directory under Pods/spec.name.
    #
    # @return [void]
    #
    def check_file_patterns
      puts spec.preserve_paths
      [:source_files, :resources, :preserve_paths].each do |attr_name|
        attr = Specification::DSL.attributes.find{|attr| attr.name == attr_name }
        if !attr.empty?(spec) && @pod.send(attr_name).empty?
          error "The `#{attr_name}` pattern did not match any file."
        end
      end

      unless @pod.license_file || spec.license && ( spec.license[:type] == 'Public Domain' || spec.license[:text] )
        warning "Unable to find a license file"
      end
    end

    #-----------------------------------------------------------------------#

    private

    # !@group Helpers

    def error(message)
      add_result(:error, message)
    end

    def warning(message)
      add_result(:warning, message)
    end

    def note(message)
      add_result(:note, message)
    end

    def add_result(type, message)
      result = results.find { |r| r.type == type && r.message == message }
      unless result
        result = Specification::Linter::Result.new(type, message)
        results << result
      end
      result.platforms << current_platform.name if current_platform
    end

    # @return [Podfile] a podfile that requires the specification on the
    # current platform.
    #
    # @note   The generated podfile takes into account whether the linter is
    #         in local mode.
    #
    def podfile_from_spec(platform)
      name     = spec.name
      podspec  = file.realpath
      local    = local?
      podfile  = Pod::Podfile.new do
        platform(platform.to_sym, platform.deployment_target)
        if (local)
          pod name, :local => podspec.dirname.to_s
        else
          pod name, :podspec => podspec.to_s
        end
      end
      podfile
    end

    # @return [Pathname] the root of the installed pod.
    #
    def pod_dir
      validation_dir + 'Pods' + spec.name
    end

    # Parse the xcode build output to identify the lines which are relevant
    # to the linter. It also removes the indentation and the temporary path.
    #
    # @param  [String] output the output generated by the xcodebuild tool.
    #
    # @return [Array<String>] the lines that are relevant to the linter.
    #
    def parse_xcodebuild_output(output)
      lines = output.split("\n")
      selected_lines = lines.select do |l|
        l.include?('error: ') &&
          (l !~ /errors? generated\./) && (l !~ /error: \(null\)/)  ||
          l.include?('warning: ') && (l !~ /warnings? generated\./) ||
          l.include?('note: ') && (l !~ /expanded from macro/)
      end
      selected_lines.map do |l|
        new = l.gsub(/\/tmp\/CocoaPods\/Lint\/Pods\//,'') # Remove the unnecessary tmp path
        new.gsub!(/^ */,' ')                              # Remove indentation
        "XCODEBUILD > " << new                            # Mark
      end
    end

    #
    #
    def print_messages(type, messages)
      return if config.silent?
      messages.each {|msg| UI.puts "    - #{type.ljust(5)} | #{msg}"}
    end
  end
end