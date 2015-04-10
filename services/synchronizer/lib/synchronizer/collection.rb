# encoding: utf-8
require 'eventmachine'
require 'pg/em'
require 'yaml'
require 'resque'
require_relative '../../../../app/models/log'
require_relative '../../../../app/models/synchronization/member'
require_relative '../../../../lib/resque/synchronization_jobs'

unless defined? Cartodb
  config = YAML.load_file(
    File.join(File.dirname(__FILE__), '../../../../config/app_config.yml') )[ENV['RAILS_ENV'] || 'development']
  Resque.redis = "#{config['redis']['host']}:#{config['redis']['port']}"
end

module CartoDB
  module Synchronizer
    class Collection

      STALLING_MAX_TIME = 3600*3

      DEFAULT_RELATION      = 'synchronizations'

      DATABASE_CONFIG_YAML  = File.join(
        File.dirname(__FILE__), '../../../../config/database.yml'
      )

      def initialize(pg_options={}, relation=DEFAULT_RELATION)
        pg_options = default_pg_options.merge(pg_options) if pg_options.empty?
        pg_options.store(:dbname, pg_options.delete(:database))

        @db       = PG::EM::Client.new(pg_options)
        @relation = relation
        @records  = [] 
      end

      def print_log(message, error=false)
        puts message if error || ENV['VERBOSE']
      end

      def run
        fetch
        process

        print_log 'Pass finished'
      end

      # Fetches and enqueues all syncs that should run
      # @param force_all_syncs bool
      def fetch(force_all_syncs=false)
        begin
          if force_all_syncs
            query = db.query(%Q(
              SELECT name, id FROM #{relation} WHERE
              state = '#{CartoDB::Synchronization::Member::STATE_SUCCESS}'
              OR state = '#{CartoDB::Synchronization::Member::STATE_SYNCING}'
            ))
          else
            query = db.query(%Q(
              SELECT name, id FROM #{relation}
              WHERE EXTRACT(EPOCH FROM run_at) < #{Time.now.utc.to_f}
              AND 
                (
                  state = '#{CartoDB::Synchronization::Member::STATE_SUCCESS}'
                  OR (state = '#{CartoDB::Synchronization::Member::STATE_FAILURE}'
                      AND retried_times < #{CartoDB::Synchronization::Member::MAX_RETRIES})
                )
            ))
          end
          success = true
        rescue Exception => e
          success = false
          print_log("ERROR fetching sync tables: #{e.message}, #{e.backtrace}", true)
        end

        if success
          print_log "Fetched #{query.count} records"
          query.each { |record|
            print_log "Enqueueing '#{record['name']}' (#{record['id']})"
            Resque.enqueue(Resque::SynchronizationJobs, job_id: record['id'])
            db.query(%Q(
               UPDATE #{relation} SET state = '#{CartoDB::Synchronization::Member::STATE_QUEUED}'
                WHERE id = '#{record['id']}'
             ))
          }
        end

        self
      end

      # Enqueues all syncs that got stalled (state syncing since too long).
      # This happens when we push code while a sync is being performed.
      def enqueue_stalled
        stalled_threshold = Time.now + (STALLING_MAX_TIME)

        begin
          query = db.query(%Q(
              SELECT name, id FROM #{relation}
              WHERE EXTRACT(EPOCH FROM ran_at) < #{stalled_threshold.utc.to_f}
              AND state = '#{CartoDB::Synchronization::Member::STATE_SYNCING}'
            ))
          success = true
        rescue Exception => e
          success = false
          print_log("ERROR fetching stalled sync tables: #{e.message}, #{e.backtrace}", true)
        end

        if success
          print_log "Fetched #{query.count} stalled records"
          query.each { |record|
            print_log "Enqueueing '#{record['name']}' (#{record['id']})"
            Resque.enqueue(Resque::SynchronizationJobs, job_id: record['id'])
            db.query(%Q(
               UPDATE #{relation} SET state = '#{CartoDB::Synchronization::Member::STATE_QUEUED}'
                WHERE id = '#{record['id']}'
             ))
          }
        end
      end

      # This is probably for testing purposes only, as fetch also does the processing
      def process(members=@members)
        print_log "Processing #{members.size} records"
        members.each { |member|
          print_log "Enqueueing #{member.name} (#{member.id})"
          member.enqueue
        }
      end

      attr_reader :records, :members

      private

      attr_reader :db, :relation
      attr_writer :records, :members

      def default_pg_options
        configuration = YAML.load_file(DATABASE_CONFIG_YAML)
        options       = configuration[ENV['RAILS_ENV'] || 'development']
        {
          host:       options.fetch('host'),
          port:       options.fetch('port'),
          user:       options.fetch('username'),
          password:   options.fetch('password'),
          database:   options.fetch('database')
        }
      end
    end
  end
end

