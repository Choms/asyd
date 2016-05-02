#Miscellaneous utils
module Misc
  # Gets the directories inside a path.
  #
  # @param path [String] Route to the directory where you want to list the subdirectories.
  # @return dir_array [Array] The subdirectories in the given directory.
  def self.get_dirs path
    files_array = Array.new
    entries = Dir.entries(path)
    entries.each do |d|
      d = path+"/"+d
      if FileTest.directory?(d)
        unless File.basename(d, "*").match(/^\./)
          files_array << File.basename(d, "*")
        end
      end
    end
    return files_array
  end

  # Gets the files inside a path.
  #
  # @param path [String] Route to the directory where you want to list the file.
  # @return files_array [Array] The files in the given directory.
  def self.get_files path
    files_array = Array.new
    entries = Dir.entries(path)
    entries.each do |f|
      f = path+"/"+f
      if FileTest.file?(f)
        files_array << File.basename(f, "*")
      end
    end
    return files_array
  end

  # Renders on html tree view the given path with all subdirectories
  #
  def self.render_path(path, level=0)
    nbspd = '&nbsp;' * ((level-1)*4) if level > 0
    data = '' if level == 0
    data = '<div class="accordion-heading accordion-invisible" style="display: inline-flex; width: 100%;"><a class="accordion-toggle" style="width: 100%" data-toggle="collapse" href="#collapse'+path.split("/").last+'">'+nbspd+'<i class="icon-folder-close-alt"></i> '+path.split("/").last+'</a><a href="#delFolder" class="accordion-toggle pull-right" onclick="passDataToModal(\''+path+'\', \'#delFolder\')"><i class="icon-trash"></i></a></div><div id="collapse'+path.split("/").last+'" class="accordion-body collapse out accordion-invisible">' if level > 0
    nbsp = '&nbsp;' * level*4
    Dir.foreach(path) do |entry|
      next if (entry == '..' || entry == '.')
      full_path = File.join(path, entry)
      if File.directory?(full_path)
        level = level+1
        data = data+render_path(full_path, level)+'</div>'
      else
        data = data+'<div class="accordion-inner accordion-invisible">'+nbsp+'<a href="#" onclick="editDeploy(\''+full_path+'\')"><i class="icon-file-text-alt"></i> '+entry+'</a><a href="#delFile" class="pull-right" onclick="passDataToModal(\''+full_path+'\', \'#delFile\')"><i class="icon-trash"></i></a></div>'
      end
    end
    return data
  end

  # Gets ASYD server IP address
  def get_asyd_ip
    cmd = "echo $SSH_CLIENT | awk '{ print $1}'"
    ip = self.exec_cmd(cmd).strip
    return ip
  end

  # Get max allocable forks
  def self.get_max_forks
    free_version = %x(free -V |awk '{print $4}')
    if Gem::Version.new(free_version) >= Gem::Version.new('3.3.10')
      free_mem = %x(free -m |grep Mem: |awk '{print $7}')
    else
      free_mem = %x(free -m |grep cache: |awk '{print $4}')
    end
    max_forks = free_mem.to_i / 50
    return max_forks
  end

  # Check pid existance
  # return true if process pid exists
  def self.checkpid(pid)
    begin
      return true if Process.kill 0, pid
    rescue
      return false
    end
  end

  # Round number
  def round
      return (self+0.5).floor if self > 0.0
      return (self-0.5).ceil  if self < 0.0
      return 0
  end

  # Checks if a port is open (so if the host is reachable)
  def self.is_port_open?(ip, port, pingback=false, seconds=3)
    begin
      Timeout::timeout(seconds) do
        s = TCPSocket.new(ip, port)
        s.gets if pingback
        s.close
        true
      end
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      false
    rescue Timeout::Error
      false
    end
  end

  # Executes a command on a remote host
  #
  # @param cmd [String] command to be executed
  # @return result [String] the result of executing the command
  def exec_cmd(cmd)
    3.times do |iteration|
      begin
        Net::SSH.start(self.ip, self.user, :port => self.ssh_port, :keys => "data/ssh_key", :timeout => 30, :user_known_hosts_file => "/dev/null", :compression => true) do |ssh|
          result = ssh.exec!(cmd)
          return result
        end
        break
      rescue Net::SSH::Exception => e
        return [4, e.message] if iteration == 2 # 4 == execution error
      end
    end
  end

  # Upload a file
  #
  # @param local [String] path to the local file
  # @param remote [String] remote path for uploading the file
  # @param orig [String] path to the original config file
  def upload_file(local, remote, orig)
    if remote.start_with? "~/" or remote.start_with? "$HOME/"
      remote.gsub!(/^(~|\$HOME)\//, '')
    end
    if remote.end_with?("/")
      destination = remote+File.basename(orig)
      remote_path = remote
    else
      destination = remote
      remote_path = File.dirname(remote)
    end
    3.times do |iteration|
      begin
        Net::SSH.start(self.ip, self.user, :port => self.ssh_port, :keys => "data/ssh_key", :timeout => 30, :user_known_hosts_file => "/dev/null", :compression => true) do |ssh|
          if self.user != "root"
            exit_code = nil
            ssh.open_channel do |channel|
              channel.exec("sudo mkdir -p "+remote_path) do |ch, success|
                channel.on_request("exit-status") do |ch,data|
                  exit_code = data.read_long
                end
              end
            end
            ssh.loop
            if exit_code == 0
              ssh.scp.upload!(local, "/tmp/"+File.basename(orig))
              ssh.exec("sudo mv /tmp/"+File.basename(orig)+" "+destination)
            else
              raise "Unable to create remote path '"+destination+"'"
            end
          else
            exit_code = nil
            ssh.open_channel do |channel|
              channel.exec("mkdir -p "+remote_path) do |ch, success|
                channel.on_request("exit-status") do |ch,data|
                  exit_code = data.read_long
                end
              end
            end
            ssh.loop
            if exit_code == 0
              ssh.scp.upload!(local, destination)
            else
              raise "Unable to create remote path '"+destination+"'"
            end
          end
        end
        break
      rescue Net::SSH::Exception => e
        return [4, e.message] if iteration == 2 # 4 == execution error
      rescue Exception => e
        return [4, e.message]
      end
    end
  end

  # Download a file
  #
  # @param remote [String] remote path of the file
  # @param local [String] local path to store the file
  def download_file(remote, local)
    if remote.start_with? "~/" or remote.start_with? "$HOME/"
      remote.gsub!(/^(~|\$HOME)\//, '')
    end
    3.times do |iteration|
      begin
        Net::SSH.start(self.ip, self.user, :port => self.ssh_port, :keys => "data/ssh_key", :timeout => 30, :user_known_hosts_file => "/dev/null", :compression => true) do |ssh|
          ssh.scp.download!(remote, local)
        end
        break
      rescue Net::SSH::Exception => e
        return [4, e.message] if iteration == 2 # 4 == execution error
      end
    end
  end

  # Upload a directory
  #
  # @param local [String] path to the local dir
  # @param remote [String] remote path for uploading the directory
  def upload_dir(local, remote)
    if remote.start_with? "~/" or remote.start_with? "$HOME/"
      remote.gsub!(/^(~|\$HOME)\//, '')
    end
    3.times do |iteration|
      begin
        Net::SSH.start(self.ip, self.user, :port => self.ssh_port, :keys => "data/ssh_key", :timeout => 30, :user_known_hosts_file => "/dev/null", :compression => true) do |ssh|
          match = ssh.exec!("ls "+remote)
          if !match.nil? && match.start_with?("ls:")
            ssh.scp.upload!(local, remote, options={:recursive => true})
          else
            files = Misc.get_files(local)
            files.each do |file|
              newfile = local+"/"+file
              newremote = remote+"/"+file
              self.upload_file(newfile, newremote)
            end
            dirs = Misc.get_dirs(local)
            dirs.each do |dir|
              newdir = local+"/"+dir+"/"
              newremote = remote+"/"+dir
              self.upload_dir(newdir, newremote)
            end
          end
        end
        break
      rescue Net::SSH::Exception => e
        return [4, e.message] if iteration == 2 # 4 == execution error
      end
    end
  end

  # Download a directory
  #
  # @param remote [String] remote path of the directory
  # @param local [String] local path to store the directory
  def download_dir(remote, local)
    if remote.start_with? "~/" or remote.start_with? "$HOME/"
      remote.gsub!(/^(~|\$HOME)\//, '')
    end
    3.times do |iteration|
      begin
        Net::SSH.start(self.ip, self.user, :port => self.ssh_port, :keys => "data/ssh_key", :timeout => 30, :user_known_hosts_file => "/dev/null", :compression => true) do |ssh|
          ssh.scp.download!(remote, local, :recursive => true)
        end
        break
      rescue Net::SSH::Exception => e
        return [4, e.message] if iteration == 2 # 4 == execution error
      end
    end
  end

  # Perform a reboot
  #
  def reboot
    begin
      Net::SSH.start(self.ip, self.user, :port => self.ssh_port, :keys => "data/ssh_key", :timeout => 30, :user_known_hosts_file => "/dev/null", :compression => true) do |ssh|
        if self.user != "root"
          ssh.exec("sudo reboot")
        else
          ssh.exec("reboot")
        end
      end
    rescue Net::SSH::ConnectionTimeout => e
        return false # ?
    rescue
      return true
    end
  end

  # Convert hash to host vars
  #
  def hash_to_host_vars(hash, task, prefix = "")
    hash.select{ |key, value|
      if prefix != ""
        key = key.to_s+"]"
      end
      if value.kind_of?(Array)
        i = 0
        nohash = 0
        value.each do |v|
          self.hash_to_host_vars(v, task, prefix+key.to_s+"["+i.to_s+"][") if v.kind_of?(Hash)
          nohash = nohash+1 unless v.kind_of?(Hash)
          i = i+1
        end
        if nohash == i
          HOSTEX.synchronize do
            self.add_var(prefix+key.to_s, value.to_s) #and we save the variable as a host variable
          end
          NOTEX.synchronize do
            msg = "Setting variable "+prefix+key.to_s+" with value "+value.to_s
            Notification.create(:type => :info, :dismiss => true, :host => self.hostname, :message => msg, :task => task)
          end
        end
      elsif value.kind_of?(Hash)
        self.hash_to_host_vars(value, task, prefix+key.to_s+"[")
      else
        HOSTEX.synchronize do
          self.add_var(prefix+key.to_s, value.to_s) #and we save the variable as a host variable
        end
        NOTEX.synchronize do
          msg = "Setting variable "+prefix+key.to_s+" with value "+value.to_s
          Notification.create(:type => :info, :dismiss => true, :host => self.hostname, :message => msg, :task => task)
        end
      end
    }
  end
end

# Returns true if the string is not a number
#
class String
  def nan?
    self !~ /^\s*[+-]?((\d+_?)*\d+(\.(\d+_?)*\d+)?|\.(\d+_?)*\d+)(\s*|([eE][+-]?(\d+_?)*\d+)\s*)$/
  end
end
