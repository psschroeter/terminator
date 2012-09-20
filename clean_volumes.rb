#!/usr/bin/env ruby

# Author: Peter Schroeter (peter.schroeter@rightscale.com)
#
require 'rubygems'
require 'ruby-debug'
require 'rest_connection'
require 'time'
require 'logger'
require 'trollop'

opts = Trollop::options do
  version "0.1.0"
  banner <<-EOS
Delete old volumes and snapshots across all clouds. Will delete any volumes
not in use, will delete any old snapshots other than base_image snapshots.
Have "save" in the description, nickname, or in a tag to prevent deletion

USAGE:
  EOS
  opt :debug, "Turn on debug output", :default => true
  opt :volumes_age, "Delete volumes older than X days", :type => :integer, :default => 7
  opt :snapshots_age, "Delete snapshots older than X days", :type => :integer, :default => 30
  opt :dry_run, "Don't execute final calls, just print what you would do", :default => true
end

@logger = Logger.new(STDOUT)
@logger.level = opts[:debug] ? Logger::DEBUG : Logger::INFO
ENV['REST_CONNECTION_LOG'] = "/tmp/rest_connection.log"
puts "Logging rest connection calls to: #{ENV['REST_CONNECTION_LOG']}"

SECONDS_IN_DAY = 3600*24
# save and do_not should cover human intervention cases
# install refers to "SQL2K8R2-Install-Media" volume, which silver team needs
# to build images
SAFE_WORDS = ["save", "install", "do_not", "do not", "media"]
EC2_REGIONS = [
  [1, 'us-east-1'],
  [2, 'eu-west-1'],
  [3, 'us-west-1'],
  [4, 'ap-southeast-1'],
  [5, 'ap-northeast-1'],
  [6, 'us-west-2'],
  [7, 'sa-east-1']
]

def handle_delete(item, dry_run)
  if dry_run
    delete_msg = "WOULD DELETE"
  else
    delete_msg = "DELETING"
  end

  @logger.info("#{delete_msg} #{item.href} (#{item.nickname})")
  unless dry_run
    begin
      #item.destroy
      @logger.info("Deletion successful")
    rescue Exception => e
      @logger.info("Unable to delete item: #{item.rs_id}")
      @logger.info("Exception occurred: #{e.inspect}")
    end
  end
end

def delete_items(items, age_seconds, api_15, dry_run, &blk)
  items.each do |i|
    unless api_15
      i.status = i.aws_status
      i.resource_uid = i.aws_id
      # Snapshots don't have created at field for api 1.0
      # but volumes do
      i.created_at ||= i.aws_started_at
    end
    # Google doesn't return created_at field, fall back to updated_at
    create_time = i.created_at||i.updated_at

    elapsed_secs = (Time.now - Time.parse(create_time)).to_i
    @logger.debug("RS_ID:#{i.rs_id} RESOURCE_ID:#{i.resource_uid} NICKNAME:#{i.nickname} STATE:#{i.status} AGE(HRS):#{elapsed_secs/3600}")
    if elapsed_secs < age_seconds 
      @logger.debug("Skipping #{i.resource_uid}, too young")
    elsif blk.call(i)
      handle_delete(i, dry_run)
    end
  end
end

def delete_volumes(volumes, age_seconds, api_15 = false, dry_run = false)
  delete_items(volumes, age_seconds, api_15, dry_run) do |i|
    if i.status == "available"
      if SAFE_WORDS.any? { |w| i.nickname.to_s.downcase.include?(w) } or 
        SAFE_WORDS.any? { |w| i.description.to_s.downcase.include?(w) }
        @logger.debug("Skipping #{i.resource_uid}, nickname or description contain a safe word")
        false
# commented out for slowness for now
#      elsif i.tags.any? { |tag| SAFE_WORDS.any? {|w| tag.downcase.include?(w) } }
#        @logger.debug("Skipping #{i.resource_uid} tags contain a safe word")
#        false
      else
        true
      end
    else
      false
    end
  end
end

def delete_snapshots(snapshots, age_seconds, api_15 = false, dry_run = false)
  delete_items(snapshots, age_seconds, api_15, dry_run) do |i|
    if SAFE_WORDS.any? { |w| i.nickname.to_s.downcase.include?(w) } or 
      SAFE_WORDS.any? { |w| i.description.to_s.downcase.include?(w) }
      @logger.debug("Skipping #{i.resource_uid}, nickname or description contain a safe word")
      false
    elsif i.nickname.to_s.downcase =~ /^ubuntu|^centos|^base_image/
      @logger.debug("Skipping #{i.resource_uid}, appears to be a base image snapshot") 
      false
    else
      true
    end
  end
end

###### Begin Main #######

puts "Starting run, skipping any volumes and snapshots containing words: #{SAFE_WORDS.join(' ')}"

EC2_REGIONS.each do |cloud_id, name|
  @logger.info "========== #{name} (volumes) ========="
  vols = Ec2EbsVolume.find_by_cloud_id(cloud_id.to_i)
  delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = false, opts[:dry_run])
end
EC2_REGIONS.each do |cloud_id, name|
  @logger.info "========== #{name} (snapshots) ========="
  snapshots = Ec2EbsSnapshot.find_by_cloud_id(cloud_id.to_i)
  delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = false, opts[:dry_run])
end

clouds_with_volumes = Cloud.find_all.select {|c| c.links.any? {|l| l['rel'] =~ /volume/}}
clouds_with_volumes.each do |cloud|
  @logger.info "========== #{cloud.name} (volumes) ========="
  vols = McVolume.find_all(cloud.cloud_id.to_i)
  delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = true, opts[:dry_run])
end
clouds_with_snapshots = Cloud.find_all.select {|c| c.links.any? {|l| l['rel'] =~ /snapshot/}}
clouds_with_snapshots.each do |cloud|
  @logger.info "========== #{cloud.name} (snapshots) ========="
  snapshots = McVolumeSnapshot.find_all(cloud.cloud_id.to_i)
  delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = true, opts[:dry_run])
end

