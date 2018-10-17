module WPScan
  module Controller
    # Specific Core controller to include WordPress checks
    class Core < CMSScanner::Controller::Core
      # @return [ Array<OptParseValidator::Opt> ]
      def cli_options
        [OptURL.new(['--url URL', 'The URL of the blog to scan'],
                    required_unless: %i[update help version], default_protocol: 'http')] +
          super.drop(1) + # delete the --url from CMSScanner
          [
            OptChoice.new(['--server SERVER', 'Force the supplied server module to be loaded'],
                          choices: %w[apache iis nginx],
                          normalize: %i[downcase to_sym]),
            OptBoolean.new(['--force', 'Do not check if the target is running WordPress']),
            OptBoolean.new(['--[no-]update', 'Whether or not to update the Database'],
                           required_unless: %i[url help version])
          ]
      end

      # @return [ DB::Updater ]
      def local_db
        @local_db ||= DB::Updater.new(DB_DIR)
      end

      # @return [ Boolean ]
      def update_db_required?
        if local_db.missing_files?
          raise MissingDatabaseFile if parsed_options[:update] == false

          return true
        end

        return parsed_options[:update] unless parsed_options[:update].nil?

        return false unless user_interaction? && local_db.outdated?

        output('@notice', msg: 'It seems like you have not updated the database for some time.')
        print '[?] Do you want to update now? [Y]es [N]o, default: [N]'

        Readline.readline =~ /^y/i ? true : false
      end

      def update_db
        output('db_update_started')
        output('db_update_finished', updated: local_db.update, verbose: parsed_options[:verbose])

        exit(0) unless parsed_options[:url]
      end

      def before_scan
        @last_update = local_db.last_update

        maybe_output_banner_help_and_version # From CMS Scanner

        update_db if update_db_required?
        setup_cache
        check_target_availability
        load_server_module
        check_wordpress_state
      end

      # Raises errors if the target is hosted on wordpress.com or is not running WordPress
      # Also check if the homepage_url is still the install url
      def check_wordpress_state
        raise WordPressHostedError if target.wordpress_hosted?

        if Addressable::URI.parse(target.homepage_url).path =~ %r{/wp-admin/install.php$}i

          output('not_fully_configured', url: target.homepage_url)

          exit(WPScan::ExitCode::VULNERABLE)
        end

        raise NotWordPressError unless target.wordpress? || parsed_options[:force]
      end

      # Loads the related server module in the target
      # and includes it in the WpItem class which will be needed
      # to check if directory listing is enabled etc
      #
      # @return [ Symbol ] The server module loaded
      def load_server_module
        server = target.server || :Apache # Tries to auto detect the server

        # Force a specific server module to be loaded if supplied
        case parsed_options[:server]
        when :apache
          server = :Apache
        when :iis
          server = :IIS
        when :nginx
          server = :Nginx
        end

        mod = CMSScanner::Target::Server.const_get(server)

        target.extend mod
        WPScan::WpItem.include mod

        server
      end
    end
  end
end
