if node.workorder.payLoad.has_key?('EscortedBy')

  attachments = node.workorder.payLoad.EscortedBy
  tasks = Array.new
  attachments.each do |a|
    tasks.push(a);
  end

  tasks.sort_by { |a| a[:ciAttributes][:priority] }.each do |a|

    Chef::Log.info("Loading on-demand attachment #{a[:ciName]}")

    _path = a[:ciAttributes][:path] or "/tmp/#{a[:ciName]}"
    _d = File.dirname(_path)

    directory "#{_d}" do
      owner "root"
      group "root"
      mode "0755"
      recursive true
      action :create
      not_if { File.directory?(_d) }
    end

    _source = a[:ciAttributes][:source]

    if _source.empty?

      _content = a[:ciAttributes][:content]

      file "#{_path}" do
        content _content.gsub(/\r\n?/,"\n")
        owner "root"
        group "root"
        mode "0755"
        action :create
      end

    else
      _user = a[:ciAttributes][:basic_auth_user]
      _password = a[:ciAttributes][:basic_auth_password]
      _headers = a[:ciAttributes][:headers]

      _headers = _headers.empty? ? Hash.new : JSON.parse(_headers)
      _checksum = a[:ciAttributes][:checksum] or nil

      shared_download_http "#{_source}" do
        path _path
        checksum _checksum
        headers(_headers) if _headers
        basic_auth_user _user.empty? ? nil : _user
        basic_auth_password _password.empty? ? nil : _password
        # action :nothing
        action :create_if_missing
        not_if do _source =~ /s3:\/\// end
      end

      shared_s3_file "#{_source}" do
        source _source
        path _path
        access_key_id _user
        secret_access_key _password
        owner "root"
        group "root"
        mode 0644
        action :create
        only_if do _source =~ /s3:\/\// end
      end

    end

    if a[:ciAttributes].has_key?("exec_cmd")
      _exec_cmd = a[:ciAttributes][:exec_cmd].gsub(/\r\n?/,"\n")
      bash "execute on-demand command" do
        code <<-EOH
#{_exec_cmd}
        EOH
        not_if { _exec_cmd.empty? }
      end 
    end

  end
end