require 'digest/md5'
require 'cgi'
require 'etc'
require 'uri'
require 'fileutils'
require 'puppet/type/state'
require 'puppet/server/fileserver'

module Puppet
    newtype(:file) do
        @doc = "Manages local files, including setting ownership and
            permissions, creation of both files and directories, and
            retrieving entire files from remote servers.  As Puppet matures, it
            expected that the ``file`` element will be used less and less to
            manage content, and instead native elements will be used to do so.
            
            If you find that you are often copying files in from a central
            location, rather than using native elements, please contact
            Reductive Labs and we can hopefully work with you to develop a
            native element to support what you are doing."

        newparam(:path) do
            desc "The path to the file to manage.  Must be fully qualified."
            isnamevar

            validate do |value|
                unless value =~ /^#{File::SEPARATOR}/
                    raise Puppet::Error, "File paths must be fully qualified"
                end
            end
        end

        newparam(:backup) do
            desc "Whether files should be backed up before
                being replaced.  If a filebucket is specified, files will be
                backed up there; else, they will be backed up in the same directory
                with a ``.puppet-bak`` extension,, and no backups
                will be made if backup is ``false``.
                
                To use filebuckets, you must first create a filebucket in your
                configuration:
                    
                    filebucket { main:
                        server => puppet
                    }

                The ``puppetmasterd`` daemon creates a filebucket by default,
                so you can usually back up to your main server with this
                configuration.  Once you've described the bucket in your
                configuration, you can use it in any file:

                    file { \"/my/file\":
                        source => \"/path/in/nfs/or/something\",
                        backup => main
                    }

                This will back the file up to the central server.

                At this point, the only benefits to doing so are that you do not
                have backup files lying around on each of your machines, a given
                version of a file is only backed up once, and you can restore
                any given file manually, no matter how old.  Eventually,
                transactional support will be able to automatically restore
                filebucketed files.
                "

            attr_reader :bucket
            defaultto ".puppet-bak"

            munge do |value|
                case value
                when false, "false", :false:
                    false
                when true, "true", ".puppet-bak", :true:
                    ".puppet-bak"
                when String:
                    # We can't depend on looking this up right now,
                    # we have to do it after all of the objects
                    # have been instantiated.
                    @bucket = value
                    value
                else
                    self.fail "Invalid backup type %s" %
                        value.inspect
                end
            end

            # Provide a straight-through hook for setting the bucket.
            def bucket=(bucket)
                @value = bucket
                @bucket = bucket
            end
        end

        newparam(:linkmaker) do
            desc "An internal parameter used by the *symlink*
                type to do recursive link creation."
        end

        newparam(:recurse) do
            desc "Whether and how deeply to do recursive
                management."

            newvalues(:true, :false, :inf, /^[0-9]+$/)
            munge do |value|
                newval = super(value)
                case newval
                when :true, :inf: true
                when :false: false
                else
                    newval
                end
            end
        end

        newparam(:replace) do
            desc "Whether or not to replace a file that is
                sourced but exists.  This is useful for using file sources
                purely for initialization."
            newvalues(:true, :false)
            defaultto :true
        end

        newparam(:force) do
            desc "Force the file operation.  Currently only used when replacing
                directories with links."
            newvalues(:true, :false)
            defaultto false
        end

        newparam(:ignore) do
            desc "A parameter which omits action on files matching
                specified patterns during recursion.  Uses Ruby's builtin globbing
                engine, so shell metacharacters are fully supported, e.g. ``[a-z]*``.
                Matches that would descend into the directory structure are ignored,
                e.g., ``*/*``."
       
            defaultto false

            validate do |value|
                unless value.is_a?(Array) or value.is_a?(String) or value == false
                    self.devfail "Ignore must be a string or an Array"
                end
            end
        end

        newparam(:links) do
            desc "How to handle links during file actions.  During file copying,
                ``follow`` will copy the target file instead of the link, ``manage``
                will copy the link itself, and ``ignore`` will just pass it by.
                When not copying, ``manage`` and ``ignore`` behave equivalently
                (because you cannot really ignore links entirely during local
                recursion), and ``follow`` will manage the file to which the
                link points."

            newvalues(:follow, :manage, :ignore)

            # :ignore and :manage behave equivalently on local files,
            # but don't copy remote links
            defaultto :ignore
        end

        newparam(:purge) do
            desc "Whether unmanaged files should be purged.  If you have a filebucket
                configured the purged files will be uploaded, but if you do not,
                this will destroy data.  Only use this option for generated
                files unless you really know what you are doing.  This option only
                makes sense when recursively managing directories."

            defaultto :false

            newvalues(:true, :false)
        end

        autorequire(:file) do
            cur = []
            pary = self[:path].split(File::SEPARATOR)
            pary.shift # remove the initial nil
            pary.pop   # remove us

            pary.inject([""]) do |ary, dir|
                ary << dir
                cur << ary.join(File::SEPARATOR)
                ary
            end

            cur
        end

        validate do
            if self[:content] and self[:source]
                self.fail "You cannot specify both content and a source"
            end
        end

        # List files, but only one level deep.
        def self.list(base = "/")
            unless FileTest.directory?(base)
                return []
            end

            files = []
            Dir.entries(base).reject { |e|
                e == "." or e == ".."
            }.each do |name|
                path = File.join(base, name)
                if obj = self[path]
                    obj[:check] = :all
                    files << obj
                else
                    files << self.create(
                        :name => path, :check => :all
                    )
                end
            end
            files
        end

        @depthfirst = false


        def argument?(arg)
            @arghash.include?(arg)
        end

        # Determine the user to write files as.
        def asuser
            if self.should(:owner) and ! self.should(:owner).is_a?(Symbol)
                writeable = Puppet::SUIDManager.asuser(self.should(:owner)) {
                    FileTest.writable?(File.dirname(self[:path]))
                }

                # If the parent directory is writeable, then we execute
                # as the user in question.  Otherwise we'll rely on
                # the 'owner' state to do things.
                if writeable
                    asuser = self.should(:owner)
                end
            end

            return asuser
        end

        # We have to do some extra finishing, to retrieve our bucket if
        # there is one
        def finish
            # Let's cache these values, since there should really only be
            # a couple of these buckets
            @@filebuckets ||= {}

            # Look up our bucket, if there is one
            if @parameters.include?(:backup) and bucket = @parameters[:backup].bucket
                case bucket
                when String:
                    if obj = @@filebuckets[bucket]
                        # This sets the @value on :backup, too
                        @parameters[:backup].bucket = obj
                    elsif obj = Puppet.type(:filebucket).bucket(bucket)
                        @@filebuckets[bucket] = obj
                        @parameters[:backup].bucket = obj
                    else
                        self.fail "Could not find filebucket %s" % bucket
                    end
                when Puppet::Client::Dipper: # things are hunky-dorey
                else
                    self.fail "Invalid bucket type %s" % bucket.class
                end
            end
            super
        end

        # Deal with backups.
        def handlebackup(file = nil)
            # let the path be specified
            file ||= self[:path]
            # if they specifically don't want a backup, then just say
            # we're good
            unless FileTest.exists?(file)
                return true
            end

            unless self[:backup]
                return true
            end

            case File.stat(file).ftype
            when "directory":
                if self[:recurse]
                    # we don't need to backup directories when recurse is on
                    return true
                else
                    backup = self[:backup]
                    case backup
                    when Puppet::Client::Dipper:
                        notice "Recursively backing up to filebucket"
                        require 'find'
                        Find.find(self[:path]) do |f|
                            if File.file?(f)
                                sum = backup.backup(f)
                                self.info "Filebucketed %s to %s with sum %s" %
                                    [f, backup.name, sum]
                            end
                        end

                        require 'fileutils'
                        FileUtils.rmtree(self[:path])
                        return true
                    when String:
                        newfile = file + backup
                        # Just move it, since it's a directory.
                        if FileTest.directory?(newfile)
                            raise Puppet::Error, "Will not replace directory backup; use a filebucket"
                        elsif FileTest.exists?(newfile)
                            begin
                                File.unlink(newfile)
                            rescue => detail
                                if Puppet[:trace]
                                    puts detail.backtrace
                                end
                                self.err "Could not remove old backup: %s" %
                                    detail
                                return false
                            end
                        end
                        begin
                            bfile = file + backup

                            # Ruby 1.8.1 requires the 'preserve' addition, but
                            # later versions do not appear to require it.
                            FileUtils.cp_r(file, bfile, :preserve => true)
                            return true
                        rescue => detail
                            # since they said they want a backup, let's error out
                            # if we couldn't make one
                            self.fail "Could not back %s up: %s" %
                                [file, detail.message]
                        end
                    else
                        self.err "Invalid backup type %s" % backup.inspect
                        return false
                    end
                end
            when "file":
                backup = self[:backup]
                case backup
                when Puppet::Client::Dipper:
                    sum = backup.backup(file)
                    self.info "Filebucketed to %s with sum %s" %
                        [backup.name, sum]
                    return true
                when String:
                    newfile = file + backup
                    if FileTest.exists?(newfile)
                        begin
                            File.unlink(newfile)
                        rescue => detail
                            self.err "Could not remove old backup: %s" %
                                detail
                            return false
                        end
                    end
                    begin
                        # FIXME Shouldn't this just use a Puppet object with
                        # 'source' specified?
                        bfile = file + backup

                        # Ruby 1.8.1 requires the 'preserve' addition, but
                        # later versions do not appear to require it.
                        FileUtils.cp(file, bfile, :preserve => true)
                        return true
                    rescue => detail
                        # since they said they want a backup, let's error out
                        # if we couldn't make one
                        self.fail "Could not back %s up: %s" %
                            [file, detail.message]
                    end
                else
                    self.err "Invalid backup type %s" % backup.inspect
                    return false
                end
            else
                self.notice "Cannot backup files of type %s" %
                    File.stat(file).ftype
                return false
            end
        end
        
        def handleignore(children)
            return children unless self[:ignore]
            self[:ignore].each { |ignore|
                ignored = []
                Dir.glob(File.join(self[:path],ignore), File::FNM_DOTMATCH) {
                    |match| ignored.push(File.basename(match))
                }
                children = children - ignored
            }
            return children
        end
          
        def initialize(hash)
            # Store a copy of the arguments for later.
            tmphash = hash.to_hash

            # Used for caching clients
            @clients = {}

            super
            # Clean out as many references to any file paths as possible.
            # This was the source of many, many bugs.
            @arghash = tmphash
            @arghash.delete(self.class.namevar)

            if @arghash.include?(:source)
                @arghash.delete(:source)
            end

            if @arghash.include?(:parent)
                @arghash.delete(:parent)
            end

            @stat = nil
        end
        
        # Create a new file or directory object as a child to the current
        # object.
        def newchild(path, local, hash = {})
            # make local copy of arguments
            args = @arghash.dup

            if path =~ %r{^#{File::SEPARATOR}}
                self.devfail(
                    "Must pass relative paths to PFile#newchild()"
                )
            else
                path = File.join(self[:path], path)
            end

            args[:path] = path

            unless hash.include?(:recurse)
                if args.include?(:recurse)
                    if args[:recurse].is_a?(Integer)
                        args[:recurse] -= 1 # reduce the level of recursion
                    end
                end

            end

            hash.each { |key,value|
                args[key] = value
            }

            child = nil
            klass = nil

            # We specifically look in @parameters here, because 'linkmaker' isn't
            # a valid attribute for subclasses, so using 'self[:linkmaker]' throws
            # an error.
            if @parameters.include?(:linkmaker) and 
                args.include?(:source) and ! FileTest.directory?(args[:source])
                klass = Puppet.type(:symlink)

                # clean up the args a lot for links
                old = args.dup
                args = {
                    :ensure => old[:source],
                    :path => path
                }
            else
                klass = self.class
            end

            # The child might already exist because 'localrecurse' runs
            # before 'sourcerecurse'.  I could push the override stuff into
            # a separate method or something, but the work is the same other
            # than this last bit, so it doesn't really make sense.
            if child = klass[path]
                unless @children.include?(child)
                    self.debug "Not managing more explicit file %s" %
                        path
                    return nil
                end

                # This is only necessary for sourcerecurse, because we might have
                # created the object with different 'should' values than are
                # set remotely.
                unless local
                    args.each { |var,value|
                        next if var == :path
                        next if var == :name
                        # behave idempotently
                        unless child.should(var) == value
                            child[var] = value
                        end
                    }
                end
            else # create it anew
                #notice "Creating new file with args %s" % args.inspect
                args[:parent] = self
                begin
                    child = klass.implicitcreate(args)
                    
                    # implicit creation can return nil
                    if child.nil?
                        return nil
                    end
                    @children << child
                rescue Puppet::Error => detail
                    self.notice(
                        "Cannot manage: %s" %
                            [detail.message]
                    )
                    self.debug args.inspect
                    child = nil
                rescue => detail
                    self.notice(
                        "Cannot manage: %s" %
                            [detail]
                    )
                    self.debug args.inspect
                    child = nil
                end
            end
            return child
        end

        # Paths are special for files, because we don't actually want to show
        # the parent's full path.
        def path
            unless defined? @path
                if defined? @parent
                    # We only need to behave specially when our parent is also
                    # a file
                    if @parent.is_a?(self.class)
                        # Remove the parent file name
                        ppath = @parent.path.sub(/\/?file=.+/, '')
                        @path = []
                        if ppath != "/" and ppath != ""
                            @path << ppath
                        end
                        @path << self.class.name.to_s + "=" + self.name
                    else
                        super
                    end
                else
                    # The top-level name is always puppet[top], so we don't
                    # bother with that.  And we don't add the hostname
                    # here, it gets added in the log server thingy.
                    if self.name == "puppet[top]"
                        @path = ["/"]
                    else
                        # We assume that if we don't have a parent that we
                        # should not cache the path
                        @path = [self.class.name.to_s + "=" + self.name]
                    end
                end
            end

            return @path.join("/")
        end

        # Recurse into the directory.  This basically just calls 'localrecurse'
        # and maybe 'sourcerecurse'.
        def recurse
            recurse = self[:recurse]
            # we might have a string, rather than a number
            if recurse.is_a?(String)
                if recurse =~ /^[0-9]+$/
                    recurse = Integer(recurse)
                #elsif recurse =~ /^inf/ # infinite recursion
                else # anything else is infinite recursion
                    recurse = true
                end
            end

            # are we at the end of the recursion?
            #if recurse == 0
            unless self.recurse?
                return
            end

            if recurse.is_a?(Integer)
                recurse -= 1
            end

            self.localrecurse(recurse)
            if @states.include? :target
                self.linkrecurse(recurse)
            end
            if @states.include?(:source)
                self.sourcerecurse(recurse)
            end
        end

        def recurse?
            return false unless @parameters.include?(:recurse)

            val = @parameters[:recurse].value

            if val and (val == true or val > 0)
                return true
            else
                return false
            end
        end

        # Build a recursive map of a link source
        def linkrecurse(recurse)
            target = @states[:target].should

            method = :lstat
            if self[:links] == :follow
                method = :stat
            end

            targetstat = nil
            unless FileTest.exist?(target)
                #self.info "%s does not exist; not recursing" %
                #    target
                return
            end
            # Now stat our target
            targetstat = File.send(method, target)
            unless targetstat.ftype == "directory"
                #self.info "%s is not a directory; not recursing" %
                #    target
                return
            end

            # Now that we know our corresponding target is a directory,
            # change our type
            self[:ensure] = :directory

            unless FileTest.readable? target
                self.notice "Cannot manage %s: permission denied" % self.name
                return
            end

            children = Dir.entries(target).reject { |d| d =~ /^\.+$/ }
         
            #Get rid of ignored children
            if @parameters.include?(:ignore)
                children = handleignore(children)
            end  

            added = []
            children.each do |file|
                Dir.chdir(target) do
                    longname = File.join(target, file)

                    # Files know to create directories when recursion
                    # is enabled and we're making links
                    args = {
                        :recurse => recurse,
                        :ensure => longname
                    }

                    if child = self.newchild(file, true, args)
                        unless @children.include?(child)
                            self.push child
                            added.push file
                        end
                    end
                end
            end
        end

        # Build up a recursive map of what's around right now
        def localrecurse(recurse)
            unless FileTest.exist?(self[:path]) and self.stat.directory?
                #self.info "%s is not a directory; not recursing" %
                #    self[:path]
                return
            end

            unless FileTest.readable? self[:path]
                self.notice "Cannot manage %s: permission denied" % self.name
                return
            end

            children = Dir.entries(self[:path])
         
            #Get rid of ignored children
            if @parameters.include?(:ignore)
                children = handleignore(children)
            end  

            added = []
            children.each { |file|
                file = File.basename(file)
                next if file =~ /^\.\.?$/ # skip . and .. 
                options = {:recurse => recurse}

                if child = self.newchild(file, true, options)
                    # Mark any unmanaged files for removal if purge is set.
                    # Use the array rather than [] because tidy uses this method, too.
                    if @parameters.include?(:purge) and self[:purge] == :true and child.implicit?
                        child[:ensure] = :absent
                    end

                    unless @children.include?(child)
                        self.push child
                        added.push file
                    end
                end
            }
        end

        # This recurses against the remote source and makes sure the local
        # and remote structures match.  It's run after 'localrecurse'.
        def sourcerecurse(recurse)
            # FIXME sourcerecurse should support purging non-remote files
            source = @states[:source].source

            unless ! source.nil? and source !~ /^\s*$/
                self.notice "source %s does not exist" % @states[:source].should
                return nil
            end
            
            sourceobj, path = uri2obj(source)

            # we'll set this manually as necessary
            if @arghash.include?(:ensure)
                @arghash.delete(:ensure)
            end

            # okay, we've got our source object; now we need to
            # build up a local file structure to match the remote
            # one

            server = sourceobj.server
            sum = "md5"
            if state = self.state(:checksum)
                sum = state.checktype
            end
            r = false
            if recurse
                unless recurse == 0
                    r = 1
                end
            end

            ignore = self[:ignore]

            desc = server.list(path, self[:links], r, ignore)

            # Now create a new child for every file returned in the list.
            desc.split("\n").each { |line|
                file, type = line.split("\t")
                next if file == "/" # skip the listing object
                name = file.sub(/^\//, '')
                args = {:source => source + file}
                if type == file
                    args[:recurse] = nil
                end

                self.newchild(name, false, args)
            }
        end

        # a wrapper method to make sure the file exists before doing anything
        def retrieve
            if @states.include?(:source)
                # This probably isn't the best place for it, but we need
                # to make sure that we have a corresponding checksum state.
                unless @states.include?(:checksum)
                    self[:checksum] = "md5"
                end

                # We have to retrieve the source info before the recursion happens,
                # although I'm not exactly clear on why.
                @states[:source].retrieve
            end

            if @parameters.include?(:recurse)
                self.recurse
            end

            unless stat = self.stat(true)
                self.debug "File does not exist"
                @states.each { |name,state|
                    # We've already retrieved the source, and we don't
                    # want to overwrite whatever it did.  This is a bit
                    # of a hack, but oh well, source is definitely special.
                    next if name == :source
                    state.is = :absent
                }

                return
            end

            states().each { |state|
                # We don't want to call 'describe()' twice, so only do a local
                # retrieve on the source.
                if state.name == :source
                    state.retrieve(false)
                else
                    state.retrieve
                end
            }
        end

        # Set the checksum, from another state.  There are multiple states that
        # modify the contents of a file, and they need the ability to make sure
        # that the checksum value is in sync.
        def setchecksum(sum = nil)
            if @states.include? :checksum
                if sum
                    @states[:checksum].checksum = sum
                else
                    # If they didn't pass in a sum, then tell checksum to
                    # figure it out.
                    @states[:checksum].retrieve
                    @states[:checksum].checksum = @states[:checksum].is
                end
            end
        end

        # Stat our file.  Depending on the value of the 'links' attribute, we use
        # either 'stat' or 'lstat', and we expect the states to use the resulting
        # stat object accordingly (mostly by testing the 'ftype' value).
        def stat(refresh = false)
            method = :stat

            # Files are the only types that support links
            if self.class.name == :file and self[:links] != :follow
                method = :lstat
            end
            path = self[:path]
            # Just skip them when they don't exist at all.
            unless FileTest.exists?(path) or FileTest.symlink?(path)
                @stat = nil
                return @stat
            end
            if @stat.nil? or refresh == true
                begin
                    @stat = File.send(method, self[:path])
                rescue Errno::ENOENT => error
                    @stat = nil
                rescue Errno::EACCES => error
                    self.warning "Could not stat; permission denied"
                    @stat = nil
                end
            end

            return @stat
        end

        def uri2obj(source)
            sourceobj = FileSource.new
            path = nil
            unless source
                devfail "Got a nil source"
            end
            if source =~ /^\//
                source = "file://localhost/%s" % URI.escape(source)
                sourceobj.mount = "localhost"
                sourceobj.local = true
            end
            begin
                uri = URI.parse(URI.escape(source))
            rescue => detail
                self.fail "Could not understand source %s: %s" %
                    [source, detail.to_s]
            end

            case uri.scheme
            when "file":
                unless defined? @@localfileserver
                    @@localfileserver = Puppet::Server::FileServer.new(
                        :Local => true,
                        :Mount => { "/" => "localhost" },
                        :Config => false
                    )
                    #@@localfileserver.mount("/", "localhost")
                end
                sourceobj.server = @@localfileserver
                path = "/localhost" + uri.path
            when "puppet":
                args = { :Server => uri.host }
                if uri.port
                    args[:Port] = uri.port
                end
                # FIXME We should cache a copy of this server
                #sourceobj.server = Puppet::NetworkClient.new(args)
                unless @clients.include?(source)
                    @clients[source] = Puppet::Client::FileClient.new(args)
                end
                sourceobj.server = @clients[source]

                tmp = uri.path
                if tmp =~ %r{^/(\w+)}
                    sourceobj.mount = $1
                    path = tmp
                    #path = tmp.sub(%r{^/\w+},'') || "/"
                else
                    self.fail "Invalid source path %s" % tmp
                end
            else
                self.fail "Got other recursive file proto %s from %s" %
                        [uri.scheme, source]
            end

            return [sourceobj, path.sub(/\/\//, '/')]
        end

        # Write out the file.  We open the file correctly, with all of the
        # uid and mode and such, and then yield the file handle for actual
        # writing.
        def write(usetmp = true)
            mode = self.should(:mode)

            #if FileTest.exists?(self[:path])
            if s = stat(false)
                # this makes sure we have a copy for posterity
                @backed = self.handlebackup

                if s.ftype == "link" and self[:links] != :follow
                    # Remove existing links, since we're writing out a file
                    File.unlink(self[:path])
                end
            end

            # The temporary file
            path = nil
            if usetmp
                path = self[:path] + ".puppettmp"
            else
                path = self[:path]
            end

            # As the correct user and group
            Puppet::SUIDManager.asuser(asuser(), self.should(:group)) do
                f = nil
                # Open our file with the correct modes
                if mode
                    Puppet::Util.withumask(000) do
                        f = File.open(path,
                            File::CREAT|File::WRONLY|File::TRUNC, mode)
                    end
                else
                    f = File.open(path, File::CREAT|File::WRONLY|File::TRUNC)
                end

                # Yield it
                yield f

                f.flush
                f.close
            end

            # And put our new file in place
            if usetmp
                begin
                    File.rename(path, self[:path])
                rescue => detail
                    self.err "Could not rename tmp %s for replacing: %s" %
                        [self[:path], detail]
                ensure
                    # Make sure the created file gets removed
                    if FileTest.exists?(path)
                        File.unlink(path)
                    end
                end
            end

            # And then update our checksum, so the next run doesn't find it.
            # FIXME This is extra work, because it's going to read the whole
            # file back in again.
            self.setchecksum
        end
    end # Puppet.type(:pfile)

    # the filesource class can't include the path, because the path
    # changes for every file instance
    class FileSource
        attr_accessor :mount, :root, :server, :local
    end

    # We put all of the states in separate files, because there are so many
    # of them.  The order these are loaded is important, because it determines
    # the order they are in the state list.
    require 'puppet/type/pfile/checksum'
    require 'puppet/type/pfile/content'     # can create the file
    require 'puppet/type/pfile/source'      # can create the file
    require 'puppet/type/pfile/target'
    require 'puppet/type/pfile/ensure'      # can create the file
    require 'puppet/type/pfile/uid'
    require 'puppet/type/pfile/group'
    require 'puppet/type/pfile/mode'
    require 'puppet/type/pfile/type'
end
# $Id$
