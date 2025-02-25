require 'chef/knife'
require 'chef/exceptions'
require 'chef/cookbook_loader'
require 'chef/cookbook_uploader'

#require 'chef/pack'
require 'chef/knife/core/object_loader'
require 'chef/json_compat'

$:.unshift File.dirname(__FILE__)
require 'pack'
require 'bundler'


ENV['BUNDLE_GEMFILE'] ||= File.dirname(__FILE__) + '/../../../Gemfile'
require 'bundler/setup' if File.exists?(ENV['BUNDLE_GEMFILE'])

Bundler.setup(:default)

require 'cms'
require 'kramdown'


class Chef
  class Knife
    class PackSync < Chef::Knife

      banner "knife pack sync PACK (options)"

      option :all,
        :short => "-a",
        :long => "--all",
        :description => "Sync all packs"

      option :type,
        :short => "-t TYPE",
        :long => "--type TYPE",
        :description => "Limit to the specified type [iaas|platform]"

      option :register,
        :short => "-r REGISTER",
        :long => "--register REGISTER",
        :description => "Specify the source register name to use during sync"

      option :version,
        :short => "-v VERSION",
        :long => "--version VERSION",
        :description => "Specify the source register version to use during sync"

      option :cookbook_path,
        :short => "-o PATH:PATH",
        :long => "--cookbook-path PATH:PATH",
        :description => "A colon-separated path to look for cookbooks in",
        :proc => lambda { |o| o.split(":") }

      option :reload,
        :long => "--reload",
        :description => "Remove the current pack before uploading"

      option :msg,
        :short => '-m MSG',
        :long => '--msg MSG',
        :description => "Append a message to the comments"

      def packs_loader
        @packs_loader ||= Knife::Core::ObjectLoader.new(Chef::Pack, ui)
      end

      def run
        config[:pack_path] ||= Chef::Config[:pack_path]
        config[:register] ||= Chef::Config[:register]
        config[:version] ||= Chef::Config[:version]

        comments = "#{ENV['USER']}:#{$0}"
        comments += " #{config[:msg]}" if config[:msg]

        if config[:all]
          config[:pack_path].each do |dir|
            pack_file_pattern = "#{dir}/*.rb"
            files = Dir.glob(pack_file_pattern)
            files.each do |file|
              if !upload_template_from_file(file,comments)
                ui.error("exiting")
                exit 1
              end
            end
          end

        else
          if @name_args.empty?
            ui.error "You must specify the pack name or use the --all option."
            exit 1
          end
          @name_args.each do |pack|
            file = [pack,'rb'].join('.')
            if !upload_template_from_file(file,comments)
                ui.error("exiting")
                exit 1
            end
          end
        end

      end

      
      def get_remote_dir
           if !@remote_dir.nil?
              return @remote_dir
           end
           
           conn = get_connection
           env_bucket = Chef::Config[:environment_name]
 
           @remote_dir = conn.directories.get env_bucket
           if @remote_dir.nil?
             @remote_dir = conn.directories.create :key => env_bucket
             puts "created #{env_bucket}"
           end
           puts "remote_dir:\n #{@remote_dir.inspect}"
 
       end
       
       def get_connection
         
         if !@object_store_connection.nil?
           return @object_store_connection
         end
         object_store_provider = Chef::Config[:object_store_provider]
 
         case object_store_provider
         when "OpenStack"   
           conn = Fog::Storage.new({
             :provider            => object_store_provider,
             :openstack_username  => Chef::Config[:object_store_user],
             :openstack_api_key   => Chef::Config[:object_store_pass],
             :openstack_auth_url  => Chef::Config[:object_store_endpoint]
           })
         when "Local"
           conn = Fog::Storage.new({
             :provider    => object_store_provider,
             :local_root  => Chef::Config[:object_store_local_root]
           })           
         end
         
         if conn.nil?
           puts "unsupported provider: #{object_store_provider}"
           exit 1
         end       
         @object_store_connection = conn
         
         return conn        
       end

      def gen_doc(ns,pack)
        
        if !Chef::Config.has_key?("object_store_provider") ||
            Chef::Config[:object_store_provider].nil? || Chef::Config[:object_store_provider].empty?
          puts "skipping doc - no object_store_provider"
          return
        end
                
         remote_dir = get_remote_dir
         initial_dir = Dir.pwd
         doc_dir = initial_dir + '/packs/doc'
           
         if File.directory? doc_dir 
           Dir.chdir doc_dir
           ["#{pack.name}.md","#{pack.name}.png"].each do |file| 
             remote_file = ns  + '/' + file
             local_file = doc_dir + '/' + file
             if !File.exists?(local_file)
               puts "missing local file: #{local_file}"
               next
             end
             if file =~ /\.md$/
                content = Kramdown::Document.new(File.read(local_file)).to_html
                remote_file.gsub!(".md",".html")
                File.write(local_file.gsub(".md",".html"), content)
             else
                content = File.open(local_file)
             end
             # remove first slash in ns path
             remote_file = remote_file[1..-1]
             puts "doc: #{local_file} remote: #{remote_file}"
             file = @remote_dir.files.create :key => remote_file, :body => content
           end
         end
         Dir.chdir initial_dir
      end

      
      def upload_template_from_file(file,comments)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"

        unless ensure_path_exists(source)
          return false
        end

        pack = packs_loader.load_from("packs", file)

        # default to the global knife version if not specified
        pack.version(config[:version].split(".").first) if pack.version.empty?
        #puts "PACK: #{pack.to_yaml}"

        if config[:reload]
          if remove_pack_version(pack,comments)
            ui.info( "Removed pack #{pack.name} version #{pack.version}")
          else
            ui.error( "Unable to remove namespace for pack #{pack.name} version #{pack.version}")
            return false
          end
        end

        signature = Digest::MD5.hexdigest(pack.signature)
        if check_pack_version(pack,signature)
          return true
        else
          if remove_pack_version(pack,comments)
            ui.info( "Removed pack #{pack.name} version #{pack.version}")
          else
            ui.error( "Unable to remove namespace for pack #{pack.name} version #{pack.version}")
            return false
          end
        end

        if pack.ignore
          ui.info( "Ignoring pack #{pack.name} version #{pack.version}")
          return true
        end

        ui.info( "Uploading pack #{pack.name}")
        Log.debug(pack.to_yaml)

        # setup pack version namespace first
        pack_version = setup_pack_version(pack,comments,'')
        if pack_version.nil?
          ui.error( "Unable to setup namespace for pack #{pack.name} version #{pack.version}")
          return false
        end
        # Upload design template
        design_resources = pack.design_resources
        Chef::Log.debug([pack.name.capitalize,'mgmt.catalog',design_resources,comments].to_yaml)
        ns = "#{source}/#{pack.name}/#{pack.version}"
        upload_template(ns,pack.name,'mgmt.catalog',pack,'_default',design_resources,comments)
        gen_doc(ns,pack)
        # Upload manifest templates
        pack.environments.each do |name,env|
          environment_resources = pack.environment_resources(name)
          #template_name = [pack.name.capitalize,name].join('-')
          template_name = pack.name
          package = 'mgmt.manifest'
          Chef::Log.debug([template_name,'mgmt.manifest',environment_resources,comments].to_yaml)
          mode = setup_mode(pack,name,comments)
          if mode.nil?
            ui.error( "Unable to setup namespace for pack #{pack.name} version #{pack.version} environment mode #{name}")
          return false
          end
          upload_template(ns+"/#{name}",template_name,'mgmt.manifest',pack,name,environment_resources,comments)
          
        end
        ui.info( "Uploaded pack #{pack.name}")
        pack_version = setup_pack_version(pack,comments,signature)
        if pack_version.nil?
          ui.error( "Unable to setup namespace for pack #{pack.name} version #{pack.version}")
          return false
        end        
        return true
      end

      private

      def check_pack_version(pack,signature)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"
        pack_version = Cms::Ci.first( :params => { :nsPath => "#{source}/#{pack.name}", :ciClassName => 'mgmt.Version', :ciName => pack.version })
        if pack_version.nil?
          ui.info( "Pack #{pack.name} version #{pack.version} not found")
          return false
        else
          if pack_version.ciAttributes.attributes.key?('commit') && pack_version.ciAttributes.commit == signature
            ui.info("Pack #{pack.name} version #{pack.version} matches signature #{signature}, use --reload to force load.")
            return true
          else
            ui.warn("Pack #{pack.name} version #{pack.version} signature is different from file signature #{signature}")
            return false
          end
        end
      end

      def remove_pack_version(pack,comments)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"
        pack_version = Cms::Ci.first( :params => { :nsPath => "#{source}/#{pack.name}", :ciClassName => 'mgmt.Version', :ciName => pack.version })
        if pack_version.nil?
          ui.info( "Pack #{pack.name} version #{pack.version} not found")
        return true
        else
          if destroy(pack_version)
            ui.info("Removed pack #{pack.name} version #{pack.version}")
          return true
          else
            ui.error("Could not remove pack #{pack.name} version #{pack.version}")
          return false
          end
        end
      end

      def setup_pack_version(pack,comments,signature)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"
        pack_ci = Cms::Ci.first( :params => { :nsPath => "#{source}", :ciClassName => 'mgmt.Pack', :ciName => pack.name })
        if pack_ci.nil?
          ui.info( "Creating pack #{pack.name}")
          unless pack_ci = build('Cms::Ci', :nsPath => "#{source}", :ciClassName => 'mgmt.Pack', :ciName => pack.name )
            ui.error("Could not create pack #{pack.name}")
          return false
          end
        else
          ui.info("Updating pack #{pack.name}")
        end

        pack_ci.comments = comments
        pack_ci.ciAttributes.pack_type = pack.type
        pack_ci.ciAttributes.description = pack.description
        pack_ci.ciAttributes.category = pack.category
        pack_ci.ciAttributes.owner = pack.owner

        Chef::Log.debug(pack_ci.to_json)
        if save(pack_ci)
          pack_version = Cms::Ci.first( :params => { :nsPath => "#{source}/#{pack.name}", :ciClassName => 'mgmt.Version', :ciName => pack.version })
          if pack_version.nil?
            ui.info( "Creating pack #{pack.name} version #{pack.version}")
            unless pack_version = build('Cms::Ci', :nsPath => "#{source}/#{pack.name}", :ciClassName => 'mgmt.Version', :ciName => pack.version )
              ui.error("Could not create pack #{pack.name} version #{pack.version}")
            return false
            end
          else
            ui.info("Updating pack #{pack.name} version #{pack.version}")
          end

          pack_version.comments = comments
          pack_version.ciAttributes.enabled = pack.enabled
          pack_version.ciAttributes.description = pack.description
          pack_version.ciAttributes.commit = signature

          Chef::Log.debug(pack_version.to_json)
          if save(pack_version)
            ui.info("Successfuly saved pack #{pack.name} version #{pack.version}")
          return pack_version
          else
            ui.error("Could not save pack #{pack.name} version #{pack.version}")
          return false
          end
          ui.info("Successfuly saved pack #{pack.name}")
        else
          ui.error("Could not save pack #{pack.name}")
        return false
        end
      end

      def setup_mode(pack,env,comments)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"
        mode = Cms::Ci.first( :params => { :nsPath => "#{source}/#{pack.name}/#{pack.version}", :ciClassName => 'mgmt.Mode', :ciName => env })
        if mode.nil?
          ui.info( "Creating pack #{pack.name} version #{pack.version} environment mode #{env}")
          unless mode = build('Cms::Ci', :nsPath => "#{source}/#{pack.name}/#{pack.version}", :ciClassName => 'mgmt.Mode', :ciName => env )
            ui.error("Could not create pack #{pack.name} version #{pack.version} environment mode #{env}")
          return false
          end
        else
          ui.info("Updating pack #{pack.name} version #{pack.version} environment mode #{env}")
        end

        mode.comments = comments
        mode.ciAttributes.description = pack.description

        Chef::Log.debug(mode.to_json)
        if save(mode)
          ui.info("Successfuly saved pack #{pack.name} version #{pack.version} environment mode #{env}")
        return mode
        else
          ui.error("Could not save pack #{pack.name} version #{pack.version} environment mode #{env}")
        return false
        end
      end

      def upload_template(nspath,template_name,package,pack,env,resources,comments)
        # create Platform first
        platform = upload_template_platform(nspath,template_name,package,pack,comments)
        if platform
          children = upload_template_children(nspath,platform,template_name,package,pack,env,resources,comments)
          upload_template_relations(nspath,platform,template_name,package,pack,env,resources,comments,children)
          upload_template_depends_on(nspath,pack,resources,children)
          upload_template_managed_via(nspath,pack,resources,children)
          upload_template_serviced_bys(nspath,pack,resources,children,platform,env)
          upload_template_entrypoint(nspath,pack,resources,children,platform,env)
          upload_template_serviced_by(nspath,pack,resources,children,platform,env)
          upload_template_monitors(nspath,pack,resources,children,platform,env)
          upload_template_payloads(nspath,pack,resources,children,platform,env)
          upload_template_procedures(nspath,pack,resources,children,platform,env)
          upload_template_variables(nspath,pack,package,platform,env)
        end
      end

      def upload_template_platform(nspath,template_name,package,pack,comments)
        ui.info( "============> #{pack.type}")
        ciClassName = [package,pack.type.capitalize].join('.')
        platform = Cms::Ci.first( :params => { :nsPath => nspath, :ciClassName => ciClassName, :ciName => template_name })
        if platform.nil?
          ui.info( "Creating #{ciClassName} for template #{template_name}")
          unless platform = build('Cms::Ci', :nsPath => nspath, :ciClassName => ciClassName, :ciName => template_name )
            ui.error("Could not build #{ciClassName}, skipping template #{template_name}")
          return false
          end
        else
          ui.info("Updating #{ciClassName} for template #{template_name}")
        end

        platform.comments = comments
        platform.ciAttributes.description = pack.description
        platform.ciAttributes.source = config[:register]
        platform.ciAttributes.pack = pack.name.capitalize
        platform.ciAttributes.version = pack.version
        Chef::Log.debug("SERVICES: #{pack.services.inspect}")
        platform.ciAttributes.services = pack.services.to_json if platform.ciAttributes.respond_to?('services')

        Chef::Log.debug(platform.to_json)
        if save(platform)
          ui.info("Successfuly saved #{ciClassName} for template #{template_name}")
        return platform
        else
          ui.error("Could not save #{ciClassName}, skipping template #{template_name}")
        return false
        end
      end

      def upload_template_children(nspath,platform,template_name,package,pack,env,resources,comments)
        children = Hash.new
        resources.each do |resource_name,resource|
          # make sure last / short class is capitalized
          if resource[:cookbook].include? "."
            classParts = resource[:cookbook].split(".")
            lastIndex = classParts.size-1
            classParts[lastIndex] = classParts[lastIndex].capitalize
            ciClassName = classParts.join(".")
          else
            ciClassName = resource[:cookbook].capitalize
          end

          if resource[:source]
            ciClassName = [ package, resource[:source], ciClassName ].join('.')
          else
            ciClassName = [ package, ciClassName ].join('.')
          end
          relationName = 'mgmt.Requires'
          relation = Cms::Relation.all( :params => {  :ciId => platform.id,
            :nsPath => nspath,
            :direction => 'from',
            :relationName => relationName,
            :targetClassName => ciClassName,
            :includeToCi => true
          }).select { |r| r.toCi.ciName == resource_name }.first
          if relation.nil?
            ui.info( "Creating resource #{resource_name} for #{template_name}")
            relation = build('Cms::Relation',   :relationName => relationName,
                                                :nsPath => nspath,
                                                :fromCiId => platform.id
                                   )
            ci = Cms::Ci.first( :params => { :nsPath => nspath, :ciClassName => ciClassName, :ciName => resource_name })
            if ci.nil?
              relation.toCiId = 0
              relation.toCi = build('Cms::Ci',  :nsPath => nspath,
                                                :ciClassName => ciClassName,
                                                :ciName => resource_name
                                             )
            else
              relation.toCiId = ci.id
              Log.debug(relation.inspect)
              # if relation is missing, but ci is present, save the relation only first
              if save(relation)
                ui.info("Successfuly saved resource #{resource_name} for template #{template_name}")
                relation = Cms::Relation.find(relation.id, :params => {  :nsPath => nspath, :includeToCi => true } )
              else
                ui.error("Could not save resource #{resource_name}, skipping it")
              end
            end
            unless relation
              ui.error("Could not build resource #{resource_name}, skipping it")
              next;
            end

          else
            ui.info("Updating resource #{resource_name} for template #{template_name}")
          end

          Log.debug("PRE-ATTRIBUTE: " + relation.inspect)

          relation.comments = comments
          relation.toCi.comments = comments

          # default value for template attribute is the resource name
          relation.relationAttributes.template = resource_name
          unless resource[:requires].nil?
            # requires relation attributes
            relation.relationAttributes.attributes.each do |name,value|
              if resource[:requires][name]
                relation.relationAttributes.send(name+'=',resource[:requires][name])
              end
            end
            # target class attributes
            relation.toCi.ciAttributes.attributes.each do |name,value|
              # old way - remove whn all packs cleaned up
              if pack.default_attributes[resource_name] && pack.default_attributes[resource_name].has_key?(name)
                relation.toCi.ciAttributes.send(name+'=',pack.default_attributes[resource_name][name])
              end
              # new way of default attribute definition in the resource
              if resource[:attributes] && resource[:attributes].has_key?(name)
                relation.toCi.ciAttributes.send(name+'=',resource[:attributes][name])
              end
            end
          end

          Log.debug(relation.inspect)
          if save(relation)
            ui.info("Successfuly saved resource #{resource_name} for template #{template_name}")
          children[resource_name] = relation.toCi.ciId
          else
            ui.error("Could not save resource #{resource_name}, skipping it")
          end
        end
        return children
      end

      def upload_template_relations(nspath,platform,template_name,package,pack,env,resources,comments,children)
        pack.environment_relations(env).each do |relation_name,relation|
          if children[relation[:from_resource]].nil?
            ui.error("Could not save relation #{relation[:relation_name]} between #{relation[:from_resource]} (missing resource) and #{relation[:to_resource]} in #{env}")
          elsif children[relation[:to_resource]].nil?
            ui.error("Could not save relation #{relation[:relation_name]} between #{relation[:from_resource]} and #{relation[:to_resource]} in #{env}")
          else
            scope = (env == '_default') ? 'catalog' : 'manifest'
            relationName = "mgmt.#{scope}.#{relation[:relation_name]}"
            relation_list = Cms::Relation.all( :params => {  :ciId => children[relation[:from_resource]],
              :nsPath => nspath,
              :direction => 'from',
              :relationName => relationName
            })
            relation_new = relation_list.select {|d| d.toCi.ciId == children[relation[:to_resource]]}.first unless relation_list.nil?
            if relation_new.nil?
              ui.info( "Creating relation #{relation[:relation_name]} between #{relation[:from_resource]} and #{relation[:to_resource]}")
              relation_new = build('Cms::Relation', :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => children[relation[:from_resource]],
                                                  :toCiId => children[relation[:to_resource]]
                                   )
            else
              ui.info( "Updating relation #{relation[:relation_name]} between #{relation[:from_resource]} and #{relation[:to_resource]}")
            end

            relation_new.relationAttributes.attributes.each do |name,value|
              if relation[:attributes][name]
                relation_new.relationAttributes.send(name+'=',relation[:attributes][name])
              end
            end
            Log.debug(relation_new.to_yaml)
            if save(relation_new)
              ui.info("Successfuly saved relation #{relation[:relation_name]} between #{relation[:from_resource]} and #{relation[:to_resource]}")
            else
              ui.error("Could not save relation #{relation[:relation_name]} between #{relation[:from_resource]} and #{relation[:to_resource]}")
            end
          end
        end
      end

      def upload_template_depends_on(nspath,pack,resources,children)
        resources.each do |resource_name,resource|
          unless pack.depends_on[resource_name].nil?
            pack.depends_on[resource_name].each do |do_class,attributes|
              next unless children[do_class] # skip if the target depends_on is not in this mode/env
              relationName = 'mgmt.manifest.DependsOn'
              depends_on_list = Cms::Relation.all( :params => {  :ciId => children[resource_name],
                :nsPath => nspath,
                :direction => 'from',
                :relationName => relationName
              })
              depends_on = depends_on_list.select {|d| d.toCi.ciId == children[do_class]}.first unless depends_on_list.nil?
              if depends_on.nil?
                ui.info( "Creating depends on between #{resource_name} and #{do_class}")
                depends_on = build('Cms::Relation', :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => children[resource_name],
                                                  :toCiId => children[do_class]
                                   )
              else
                ui.info( "Updating depends on between #{resource_name} and #{do_class}")
              end

              depends_on.relationAttributes.attributes.each do |name,value|
                if pack.depends_on[resource_name][do_class][name]
                  depends_on.relationAttributes.send(name+'=',pack.depends_on[resource_name][do_class][name])
                end
              end
              Log.debug(depends_on.to_yaml)
              if save(depends_on)
                ui.info("Successfuly saved depends on between #{resource_name} and #{do_class}")
              else
                ui.error("Could not save depends on between #{resource_name} and #{do_class} in #{nspath}, skipping it")
              end
            end
          end
        end
      end

      def upload_template_managed_via(nspath,pack,resources,children)
        resources.each do |resource_name,resource|
          unless pack.managed_via[resource_name].nil?
            pack.managed_via[resource_name].each do |mv_class,attributes|
              relationName = 'mgmt.manifest.ManagedVia'
              managed_via_list = Cms::Relation.all( :params => {  :ciId => children[resource_name],
                :nsPath => nspath,
                :direction => 'from',
                :relationName => relationName
              })
              managed_via = managed_via_list.select {|d| d.toCi.ciId == children[mv_class]}.first unless managed_via_list.nil?
              if managed_via.nil?
                ui.info( "Creating managed via between #{resource_name} and #{mv_class}")
                managed_via = build('Cms::Relation', :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => children[resource_name],
                                                  :toCiId => children[mv_class]
                                   )
              else
                ui.info( "Updating managed via between #{resource_name} and #{mv_class}")
              end

              managed_via.relationAttributes.attributes.each do |name,value|
                if pack.managed_via[resource_name][mv_class][name]
                  managed_via.relationAttributes.send(name+'=',pack.managed_via[resource_name][mv_class][name])
                end
              end
              Log.debug(managed_via.to_yaml)
              if save(managed_via)
                ui.info("Successfuly saved managed via between #{resource_name} and #{mv_class}")
              else
                ui.error("Could not save managed via between #{resource_name} and #{mv_class}, skipping it")
              end
            end
          end
        end
      end

      def upload_template_serviced_bys(nspath,pack,resources,children,platform,env)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"
        relationName = 'mgmt.manifest.ServicedBy'
        serviced_by_list = Cms::Relation.all( :params => {  :ciId => platform.ciId,
          :nsPath => nspath,
          :direction => 'from',
          :relationName => relationName
        })
        pack.environment_serviced_bys(env).each do |iaas_name,iaas_pack|
          serviced_by = serviced_by_list.select {|d| d.toCi.pack == iaas_pack[:pack] && d.toCi.version == iaas_pack[:version] }.first unless serviced_by_list.nil?
          if serviced_by.nil?
            ui.info( "Creating serviced by between platform and #{iaas_pack[:pack]} version #{iaas_pack[:version]}")
            iaas_path = "#{source}/#{iaas_pack[:pack]}/#{iaas_pack[:version]}/#{env}"
            iaas = Cms::Ci.all( :params=> { :nsPath => iaas_path, :ciName => iaas_pack[:pack], :ciClassName => 'mgmt.manifest.Iaas' } ).first
            if iaas.nil?
              ui.error("Could not find target Iaas pack for serviced by between platform and #{iaas_pack[:pack]} version #{iaas_pack[:version]} in #{iaas_path}, skipping it")
            else
              serviced_by = build('Cms::Relation', :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => platform.ciId,
                                                  :toCiId => iaas.ciId
                                   )
              Log.debug(serviced_by.to_yaml)
              if save(serviced_by)
                ui.info("Successfuly saved serviced by between platform and #{iaas_pack[:pack]} version #{iaas_pack[:version]}")
              else
                ui.error("Could not save serviced by between platform and #{iaas_pack[:pack]} version #{iaas_pack[:version]}, skipping it")
              end
            end
          else
            ui.info( "Existing serviced by between platform and #{iaas_pack[:pack]} version #{iaas_pack[:version]}")
          end
                  #ui.info("SERVICED_BY: #{iaas_pack.inspect}")
        end
      end

      def upload_template_entrypoint(nspath,pack,resources,children,platform,env)
        resources.each do |resource_name,resource|
          unless pack.environment_entrypoints(env)[resource_name].nil?
            relationName = 'mgmt.Entrypoint'
            entrypoint_list = Cms::Relation.all( :params => {  :ciId => platform.ciId,
              :nsPath => nspath,
              :direction => 'from',
              :relationName => relationName
            })
            entrypoint = entrypoint_list.select {|d| d.toCi.ciId == children[resource_name]}.first unless entrypoint_list.nil?
            if entrypoint.nil?
              ui.info( "Creating entrypoint between platform and #{resource_name}")
              entrypoint = build('Cms::Relation', :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => platform.ciId,
                                                  :toCiId => children[resource_name]
                                   )
            else
              ui.info( "Updating entrypoint between platform and #{resource_name}")
            end

            entrypoint.relationAttributes.attributes.each do |name,value|
              if pack.entrypoints[resource_name]['attributes'][name]
                entrypoint.relationAttributes.send(name+'=',pack.entrypoints[resource_name]['attributes'][name])
              end
            end
            Log.debug(entrypoint.to_yaml)
            if save(entrypoint)
              ui.info("Successfuly saved entrypoint between platform and #{resource_name}")
            else
              ui.error("Could not save entrypoint between platform and #{resource_name}, skipping it")
            end
          end
        end
      end

      def upload_template_serviced_by(nspath,pack,resources,children,platform,env)
        source = "#{Chef::Config[:nspath]}/#{config[:register]}/packs"
        resources.each do |resource_name,resource|
          next if resource[:serviced_by].nil?
          relationName = 'mgmt.manifest.ServicedBy'
          serviced_by_list = Cms::Relation.all( :params => {  :ciId => children[resource_name],
            :nsPath => nspath,
            :direction => 'from',
            :relationName => relationName
          })
          resource[:serviced_by].each do |iaas_pack|
            serviced_by = serviced_by_list.select {|d| d.toCi.pack == iaas_pack[:pack] && d.toCi.version == iaas_pack[:version] }.first unless serviced_by_list.nil?
            if serviced_by.nil?
              ui.info( "Creating serviced by between #{resource_name} and #{iaas_pack[:pack]} version #{iaas_pack[:version]}")
              iaas_path = "#{source}/#{iaas_pack[:pack]}/#{iaas_pack[:version]}/#{env}"
              iaas = Cms::Ci.all( :params=> { :nsPath => iaas_path, :ciName => iaas_pack[:pack], :ciClassName => 'mgmt.manifest.Iaas' } ).first
              if iaas.nil?
                ui.error("Could not find target Iaas pack for serviced by between #{resource_name} and #{iaas_pack[:pack]} version #{iaas_pack[:version]} in #{iaas_path}, skipping it")
              else
                serviced_by = build('Cms::Relation', :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => children[resource_name],
                                                  :toCiId => iaas.ciId
                                   )
                Log.debug(serviced_by.to_yaml)
                if save(serviced_by)
                  ui.info("Successfuly saved serviced by between #{resource_name} and #{iaas_pack[:pack]} version #{iaas_pack[:version]}")
                else
                  ui.error("Could not save serviced by between #{resource_name} and #{iaas_pack[:pack]} version #{iaas_pack[:version]}, skipping it")
                end
              end
            else
              ui.info( "Existing serviced by between #{resource_name} and #{iaas_pack[:pack]} version #{iaas_pack[:version]}")
            end

          end
        end
      end

      def upload_template_monitors(nspath,pack,resources,children,platform,env)
        resources.each do |resource_name,resource|
          next if resource[:monitors].nil?
          resource[:monitors].each do |monitor_name,monitor|
            relationName = 'mgmt.manifest.WatchedBy'
            ciClassName = 'mgmt.manifest.Monitor'
            relation = Cms::Relation.all( :params => {  :ciId => children[resource_name],
              :nsPath => nspath,
              :direction => 'from',
              :relationName => relationName,
              :targetClassName => ciClassName,
              :includeToCi => true
            }).select { |r| r.toCi.ciName == monitor_name }.first
            if relation.nil?
              ui.info( "Creating monitor #{monitor_name} for #{resource_name}")
              relation = build('Cms::Relation',   :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => children[resource_name]
                                   )
              ci = Cms::Ci.first( :params => { :nsPath => nspath, :ciClassName => ciClassName, :ciName => monitor_name })
              if ci.nil?
                relation.toCiId = 0
                relation.toCi = build('Cms::Ci',  :nsPath => nspath,
                                                  :ciClassName => ciClassName,
                                                  :ciName => monitor_name
                                               )
              else
                relation.toCiId = ci.id
                Log.debug(relation.inspect)
                # if relation is missing, but ci is present, save the relation only first
                if save(relation)
                  ui.info("Successfuly saved monitor #{monitor_name} for #{resource_name}")
                  relation = Cms::Relation.find(relation.id, :params => {  :nsPath => nspath, :includeToCi => true } )
                else
                  ui.error("Could not save monitor #{monitor_name} for #{resource_name}, skipping it")
                end
              end
              unless relation
                ui.error("Could not build monitor #{monitor_name} for #{resource_name}, skipping it")
                next;
              end
            else
              ui.info("Updating monitor #{monitor_name} for #{resource_name}")
            end

            # qpath attributes
            relation.toCi.ciAttributes.attributes.each do |name,value|
              if monitor[name]
                monitor[name] = monitor[name].to_json if (monitor[name].is_a?(Hash))
                relation.toCi.ciAttributes.send(name+'=',monitor[name])
              end
            end

            Log.debug(relation.inspect)
            if save(relation)
              ui.info("Successfuly saved monitor #{monitor_name} for #{resource_name}")
            else
              ui.error("Could not save monitor #{monitor_name} for #{resource_name}, skipping it")
            end

          end
        end
      end

      def upload_template_payloads(nspath,pack,resources,children,platform,env)
        resources.each do |resource_name,resource|
          next if resource[:payloads].nil?
          resource[:payloads].each do |payload_name,payload|
            relationName = 'mgmt.manifest.Payload'
            ciClassName = 'mgmt.manifest.Qpath'
            relation = Cms::Relation.all( :params => {  :ciId => children[resource_name],
              :nsPath => nspath,
              :direction => 'from',
              :relationName => relationName,
              :targetClassName => ciClassName,
              :includeToCi => true
            }).select { |r| r.toCi.ciName == payload_name }.first
            if relation.nil?
              ui.info( "Creating payload #{payload_name} for #{resource_name}")
              relation = build('Cms::Relation',   :relationName => relationName,
                                                  :nsPath => nspath,
                                                  :fromCiId => children[resource_name]
                                   )
              ci = Cms::Ci.first( :params => { :nsPath => nspath, :ciClassName => ciClassName, :ciName => payload_name })
              if ci.nil?
                relation.toCiId = 0
                relation.toCi = build('Cms::Ci',  :nsPath => nspath,
                                                  :ciClassName => ciClassName,
                                                  :ciName => payload_name
                                               )
              else
                relation.toCiId = ci.id
                Log.debug(relation.inspect)
                # if relation is missing, but ci is present, save the relation only first
                if save(relation)
                  ui.info("Successfuly saved payload #{payload_name} for #{resource_name}")
                  relation = Cms::Relation.find(relation.id, :params => {  :nsPath => nspath, :includeToCi => true } )
                else
                  ui.error("Could not save payload #{payload_name} for #{resource_name}, skipping it")
                end
              end
              unless relation
                ui.error("Could not build payload #{payload_name} for #{resource_name}, skipping it")
                next;
              end
            else
              ui.info("Updating payload #{payload_name} for #{resource_name}")
            end

            # qpath attributes
            relation.toCi.ciAttributes.attributes.each do |name,value|
              if payload[name]
                relation.toCi.ciAttributes.send(name+'=',payload[name])
              end
            end

            Log.debug(relation.inspect)
            if save(relation)
              ui.info("Successfuly saved payload #{payload_name} for #{resource_name}")
            else
              ui.error("Could not save payload #{payload_name} for #{resource_name}, skipping it")
            end

          end
        end
      end

      def upload_template_procedures(nspath,pack,resources,children,platform,env)
        pack.environment_procedures(env).each do |procedure_name,procedure_attributes|
          relationName = 'mgmt.manifest.ControlledBy'
          ciClassName = 'mgmt.manifest.Procedure'
          relation = Cms::Relation.all( :params => {  :ciId => platform.id,
            :nsPath => nspath,
            :direction => 'from',
            :relationName => relationName,
            :targetClassName => ciClassName,
            :includeToCi => true
          }).select { |r| r.toCi.ciName == procedure_name }.first
          if relation.nil?
            ui.info( "Creating procedure #{procedure_name} for environment #{env}")
            relation = build('Cms::Relation',   :relationName => relationName,
                                                :nsPath => nspath,
                                                :fromCiId => platform.id
                                   )
            ci = Cms::Ci.first( :params => { :nsPath => nspath, :ciClassName => ciClassName, :ciName => procedure_name })
            if ci.nil?
              relation.toCiId = 0
              relation.toCi = build('Cms::Ci',  :nsPath => nspath,
                                                :ciClassName => ciClassName,
                                                :ciName => procedure_name
                                             )
            else
              relation.toCiId = ci.id
              Log.debug(relation.inspect)
              # if relation is missing, but ci is present, save the relation only first
              if save(relation)
                ui.info("Successfuly saved procedure #{procedure_name} for environment #{env}")
                relation = Cms::Relation.find(relation.id, :params => {  :nsPath => nspath, :includeToCi => true } )
              else
                ui.error("Could not save procedure #{procedure_name} for environment #{env}, skipping it")
              end
            end
            unless relation
              ui.error("Could not build procedure #{procedure_name} for environment #{env}, skipping it")
              next;
            end
          else
            ui.info("Updating procedure #{procedure_name} for environment #{env}")
          end

          Log.debug("PRE-ATTRIBUTE: " + relation.inspect)

          # procedure attributes
          relation.toCi.ciAttributes.attributes.each do |name,value|
            if procedure_attributes[name]
		    if name == 'arguments' 
			procedure_attributes[name] = procedure_attributes[name].to_json if (procedure_attributes[name].is_a?(Hash))
		    end
              relation.toCi.ciAttributes.send(name+'=',procedure_attributes[name])
            end
          end

          Log.debug(relation.inspect)
          if save(relation)
            ui.info("Successfuly saved procedure #{procedure_name} for environment #{env}")
          else
            ui.error("Could not save procedure #{procedure_name} for environment #{env}, skipping it")
          end

        end
      end

      def upload_template_variables(nspath,pack,package,platform,env)
        pack.environment_variables(env).each do |variable_name,variable_attributes|
          relationName = "#{package}.ValueFor"
          ciClassName = "#{package}.Localvar"
          relation = Cms::Relation.all( :params => {  :ciId => platform.id,
            :nsPath => nspath,
            :direction => 'to',
            :relationName => relationName,
            :targetClassName => ciClassName,
            :includeFromCi => true
          }).select { |r| r.fromCi.ciName == variable_name }.first
          if relation.nil?
            ui.info( "Creating variable #{variable_name} for environment #{env}")
            relation = build('Cms::Relation',   :relationName => relationName,
                                                :nsPath => nspath,
                                                :toCiId => platform.id
                                   )
            ci = Cms::Ci.first( :params => { :nsPath => nspath, :ciClassName => ciClassName, :ciName => variable_name })
            if ci.nil?
              relation.fromCiId = 0
              relation.fromCi = build('Cms::Ci', :nsPath => nspath,
                                                 :ciClassName => ciClassName,
                                                 :ciName => variable_name
                                             )
            else
              relation.fromCiId = ci.id
              Log.debug(relation.inspect)
              # if relation is missing, but ci is present, save the relation only first
              if save(relation)
                ui.info("Successfuly saved variable #{variable_name} for environment #{env}")
                relation = Cms::Relation.find(relation.id, :params => {  :nsPath => nspath, :includeFromCi => true } )
              else
                ui.error("Could not save variable #{variable_name} for environment #{env}, skipping it")
              end
            end
            unless relation
              ui.error("Could not build variable #{variable_name} for environment #{env}, skipping it")
              next;
            end
          else
            ui.info("Updating variable #{variable_name} for environment #{env}")
          end

          Log.debug("PRE-ATTRIBUTE: " + relation.inspect)

          # procedure attributes
          relation.fromCi.ciAttributes.attributes.each do |name,value|
            if variable_attributes[name]
              relation.fromCi.ciAttributes.send(name+'=',variable_attributes[name])
            end
          end

          Log.debug(relation.inspect)
          if save(relation)
            ui.info("Successfuly saved variable #{variable_name} for environment #{env}")
          else
            ui.error("Could not save variable #{variable_name} for environment #{env}, skipping it")
          end

        end
      end

      def ensure_path_exists(nspath)
        ns = Cms::Namespace.all( :params => { :nsPath => nspath } ).first
        if ns.nil?
          ui.error("Can't find namespace #{nspath}. Please register your source first with the register command")
        end
        return ns
      end

      def save(object)
        begin
          ok = object.save
        rescue Exception => e
          Log.debug(e.response.read_body)
        end
        ok ? object : false
      end

      def destroy(object)
        begin
          ok = object.destroy
        rescue Exception => e
          Log.debug(e.response.read_body)
        end
        ok ? object : false
      end

      def build(klass, options)
        begin
          object = klass.constantize.build(options)
        rescue Exception => e
          Log.debug(e.response.read_body)
        end
        object ? object : false
      end

    end
  end
end
