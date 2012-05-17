#!/usr/bin/env ruby
#
# = gitsync.rb: Git syncronization script
#
# Author:: katsumi sahashi <sahashi@dmotion.co.jp>
# Copyright:: Copyright (C) dmotion Co,Ltd. 2012 All rights reserved.
#

require 'yaml'
require 'optparse'
require 'logger'

#
# Git Syncronization class.
#
class GitSync

  attr_reader :config
  attr_writer :config
  
  #
  # Initialization class.
  #
  def initialize( config_file, optargs )
    @config = Hash.new()

    if nil != config_file && !config_file.empty? then
      if File.exist?( config_file ) then
        @config = YAML.load_file( config_file )
      end
    end

    optargs.each do |key, value|
      @config[key] = value
    end

    # default config value
    @config['gc'] = false unless @config.has_key?( 'gc' )
    @config['loop'] = false unless @config.has_key?( 'loop' )
    @config['sleep'] = 60 unless @config.has_key?( 'sleep' )
    @config['loglevel'] = Logger::INFO unless @config.has_key?( 'loglevel' )
    @config['local_host'] = `hostname`.strip

    @log = Logger.new( STDOUT )
    @log.level = @config['loglevel']
    if Logger::DEBUG != @log.level then
      @quiet = '--quiet'
    else
      @quiet = ''
      @log.debug( @config )
    end
  end

  #
  # Execute Git command.
  #
  def git( argline, oneline=false )
    lines = Array.new
    gitline = sprintf( "| git %s", argline )
    @log.debug( gitline )

    open( gitline ) do |io|
      while line = io.gets
        lines.push( line.strip )
      end
    end

    if 0 != $? then
      raise sprintf( "git status cdoe: %d", $? )
    else
      if oneline then
        lines[0]
      else
        lines
      end
    end
  end

  #
  # Check both central, local HEAD hash.
  #
  def check_head_hash( )
    remote_head = git( 'ls-remote origin HEAD', true )
    local_head = git( 'rev-parse HEAD', true )

    if nil != remote_head && nil != local_head then
      if !remote_head.empty? then
        remote_head = remote_head.split( "\t" )[0].strip
      end
    
      @log.debug( sprintf( "remote_head: %s local_head: %s\n",
                           remote_head, local_head ) )

      return remote_head != local_head
    else
      return false
    end
  end

  #
  # Pull from central repositoy.
  #
  def sync_pull( )
    result = false

    begin
      if check_head_hash( ) then
        @log.info( 'Pull from central repository' )
        git( 'reset --hard HEAD' )
        git( sprintf( 'pull %s origin master', @quiet ) )
        result = true
      end
    rescue => ex
      @log.warn( 'Could not sync from central repository' )
      @log.error( ex )
    end

    result
  end

  #
  # Syncronization local repository.
  #
  def sync_local( )
    result = false
    add_count = 0
    change_count = 0

    git( 'status --short' ).each do |line|
      flds = line.strip.split( /\s+/ )
      xy = flds[0]
      # Todo: meny more...
      if '??' == xy then
        @log.debug( 'Untracked file: ' << flds[1] )
        add_count += 1
        change_count += 1
      elsif 'A' == xy then
        @log.debug( 'New file: ' << flds[1] )
        change_count += 1
      elsif 'M' == xy then
        @log.debug( 'Modified file: ' << flds[1] )
        change_count += 1
      elsif 'D' == xy then
        @log.debug( 'Deleted file: ' << flds[1] )
        change_count += 1
      end
    end

    if 0 < add_count then
      @log.info( 'Added to the localrepository' )
      git( 'add .' )
    end

    if 0 < change_count then
      @log.info( 'Commit to the local repository' )
      @log.info( sprintf( "Commited %d files", change_count ) )
      git( sprintf( "commit -a -m \"Commited %d files by %s of %s\"",
                    change_count, 'gitsync.rb', @config['local_host'] ) )
      result = true
    end

    result
  end

  #
  # Push central repository.
  #
  def sync_push( commited )
    begin
      if commited then
        @log.info( 'Push to the central repository' )
        git( sprintf( "push %s origin master", @quiet ) )
      else
        @log.info( 'There is no change in local' )
      end
    rescue
      @log.warn( 'Could not sync to central repository' )
    end
  end

  #
  # Git garbage collection.
  #
  def gc( run_gc )
    if @config['gc'] || run_gc then
      @log.info( 'garbage collect' )
      git( sprintf( 'gc %s', @quiet ) )
    end
  end
  
  public
  
  #
  # Start Git syncronization.
  #
  def start
    begin
      counts = Hash.new
      begin
        @config['repositories'].each do |repo|
          local_path = repo['local_path']
          count = counts[local_path] || 0
          Dir.chdir( local_path ) do
            begin
              @log.info( '>> ' + local_path )
              pulled = sync_pull( )
              commited = sync_local( )
              sync_push( commited )
              if pulled || commited  then
                count = count + 1
                if 10 < count then
                  count = 0
                end
                gc( 0 == count )
              end
              @log.info( '<< ' + local_path )
            end
          end
          counts[local_path] = count
        end
      end while @config['loop'] && sleep( @config['sleep'] )
    rescue SignalException
      @log.info( 'signal' )
    rescue Interrupt
      @log.info( 'interrupt' )
    rescue => ex
      @log.error( ex )
      raise ex
    end
  end

  #
  # init repository.
  #
  def init( config_file, initargs )
    url = (initargs['protocol'] + '://')

    if 'ssh' == initargs['protocol'] then
      unless initargs['remote_user'].empty? then
        url << (initargs['remote_user'] + '@')
      end
    end

    if 'file' != initargs['protocol'] then
      url << initargs['remote_host']
    end

    if initargs.has_key?( 'remote_port' ) &&
        !initargs['remote_port'].empty? &&
        ('ssh' == initargs['protocol'] ||
         'git' == initargs['protocol'] ||
         'rsync' == initargs['protocol'] ||
         (/^https?$/ =~ initargs['protocol']) ||
         (/^ftps?$/ =~ initargs['protocol'])) then
      url << (':' + initargs['remote_port'])
    end

    url << ('/' + initargs['remote_path'])

    @log.info( sprintf( "init local repository %s from url is %s",
                        initargs['local_path'], url ) )
    git( sprintf( "clone %s %s %s", @quiet, url, initargs['local_path'] ) )

    repositories = @config['repositories'] || Array.new
    repositories << {
      'local_path' => initargs['local_path'],
      'url' => url
    }
    @config['repositories'] = repositories

    YAML.dump( @config, File.open( config_file, "w" ) )
  end
end

if __FILE__ == $0
  optargs = Hash.new
  initargs= {
    'init' => false
  }

  config_file = File.expand_path( File.dirname( $0 ) ) + '/config.yml'
  
  opts = OptionParser.new( )
  opts.on( "--file CONFIG_FILE" ) { |v| config_file = v }

  opts.on( "--gc" ) { |v| optargs['gc'] = true }
  opts.on( "--loop" ) { |v| optargs['loop'] = true }
  opts.on( "--sleep=SLEEP" ) { |v| optargs['sleep'] = v.to_i }

  opts.on( "--init" ) { |v| initargs['init'] = true }
  opts.on( "--protocol=PROTO" ) { |v| initargs['protocol'] = v }
  opts.on( "--remote_user=USER" ) { |v| initargs['remote_user'] = v }
  opts.on( "--remote_host=HOST" ) { |v| initargs['remote_host'] = v }
  opts.on( "--remote_path=PATH" ) { |v| initargs['remote_path'] = v }
  opts.on( "--remote_port=PORT" ) { |v| initargs['remote_port'] = v }
  opts.on( "--local_path=PATH" ) { |v| initargs['local_path'] = v }

  opts.parse!( ARGV )
  
  gitsync = GitSync.new( config_file, optargs )

  if initargs['init'] then
    gitsync.init( config_file, initargs )
  else
    gitsync.start
  end
end

# Local Variables: ***
# tab-width: 4 ***
# comment-column: 48 ***
# End: ***

# vi:set ts=4 sw=4:
