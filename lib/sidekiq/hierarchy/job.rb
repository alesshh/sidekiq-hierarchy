module Sidekiq
  module Hierarchy
    class Job
      include RedisConnection

      # Job hash keys
      INFO_FIELD = 'i'.freeze
      PARENT_FIELD = 'p'.freeze
      STATUS_FIELD = 's'.freeze

      ENQUEUED_AT_FIELD = 'e'.freeze
      RUN_AT_FIELD = 'r'.freeze
      COMPLETED_AT_FIELD = 'c'.freeze

      WORKFLOW_STATUS_FIELD = 'w'.freeze
      WORKFLOW_FINISHED_AT_FIELD = 'wf'.freeze
      SUBTREE_SIZE_FIELD = 't'.freeze
      FINISHED_SUBTREE_SIZE_FIELD = 'tf'.freeze

      # Values for STATUS_FIELD
      STATUS_ENQUEUED = '0'.freeze
      STATUS_RUNNING = '1'.freeze
      STATUS_COMPLETE = '2'.freeze
      STATUS_REQUEUED = '3'.freeze
      STATUS_FAILED = '4'.freeze

      ONE_MONTH = 60 * 60 * 24 * 30  # key expiration
      INFO_KEYS = ['class'.freeze, 'queue'.freeze]  # default keys to keep


      ### Class definition

      attr_reader :jid

      def initialize(jid)
        @jid = jid
      end

      class << self
        alias_method :find, :new

        def create(jid, job_hash)
          new(jid).tap do |job|
            job[INFO_FIELD] = Sidekiq.dump_json(filtered_job_hash(job_hash))
            job.increment_subtree_size  # start at subtree size 1 -- no children
          end
        end

        # saves INFO_KEYS as well as whatever keys are specified
        # in the worker's sidekiq options under :workflow_keys
        def filtered_job_hash(job_hash)
          keys_to_keep = (INFO_KEYS + Array(job_hash['workflow_keys'])).uniq
          job_hash.select { |k, _| keys_to_keep.include?(k) }
        end
        private :filtered_job_hash
      end

      def delete
        children.each(&:delete)
        redis { |conn| conn.del(redis_children_lkey, redis_job_hkey) }
      end

      def exists?
        redis { |conn| conn.exists(redis_job_hkey) }
      end

      def ==(other_job)
        other_job.instance_of?(self.class) &&
          self.jid == other_job.jid
      end

      # Magic getter backed by redis hash
      def [](key)
        redis { |conn| conn.hget(redis_job_hkey, key) }
      end

      # Magic setter backed by redis hash
      def []=(key, value)
        redis do |conn|
          conn.multi do
            conn.hset(redis_job_hkey, key, value)
            conn.expire(redis_job_hkey, ONE_MONTH)
          end
        end
        value
      end

      def info
        Sidekiq.load_json(self[INFO_FIELD])
      end


      ### Tree exploration and manipulation

      def parent
        if parent_jid = self[PARENT_FIELD]
          self.class.find(parent_jid)
        end
      end

      def children
        redis do |conn|
          conn.lrange(redis_children_lkey, 0, -1).map { |jid| self.class.find(jid) }
        end
      end

      def root?
        parent.nil?
      end

      def leaf?
        children.none?
      end

      # Walks up the workflow tree and returns its root job node
      # Warning: recursive!
      def root
        # This could be done in a single Lua script server-side...
        self.root? ? self : self.parent.root
      end

      # Walks down the workflow tree and returns all its leaf nodes
      # If called on a leaf, returns an array containing only itself
      # Warning: recursive!
      def leaves
        # This could be done in a single Lua script server-side...
        self.leaf? ? [self] : children.flat_map(&:leaves)
      end

      # Walks the subtree rooted here in DFS order
      # Returns an Enumerator; use #to_a to get an array instead
      def subtree_jobs
        to_visit = [self]
        Enumerator.new do |y|
          while node = to_visit.pop
            y << node  # sugar for yielding a value
            to_visit += node.children
          end
        end
      end

      # The cached cardinality of the tree rooted at this job
      def subtree_size
        self[SUBTREE_SIZE_FIELD].to_i
      end

      # Recursively updates subtree size on this and all higher subtrees
      def increment_subtree_size(incr=1)
        redis { |conn| conn.hincrby(redis_job_hkey, SUBTREE_SIZE_FIELD, incr) }
        if p_job = parent
          p_job.increment_subtree_size(incr)
        end
      end

      # The cached count of the finished jobs in the tree rooted at this job
      def finished_subtree_size
        self[FINISHED_SUBTREE_SIZE_FIELD].to_i
      end

      # Recursively updates finished subtree size on this and all higher subtrees
      def increment_finished_subtree_size(incr=1)
        redis { |conn| conn.hincrby(redis_job_hkey, FINISHED_SUBTREE_SIZE_FIELD, incr) }
        if p_job = parent
          p_job.increment_finished_subtree_size(incr)
        end
      end

      # Draws a new doubly-linked parent-child relationship in redis
      def add_child(child_job)
        redis do |conn|
          conn.multi do
            # draw child->parent relationship
            conn.hset(child_job.redis_job_hkey, PARENT_FIELD, self.jid)
            conn.expire(child_job.redis_job_hkey, ONE_MONTH)
            # draw parent->child relationship
            conn.rpush(redis_children_lkey, child_job.jid)
            conn.expire(redis_children_lkey, ONE_MONTH)
          end
        end

        # updates subtree counts to reflect new child
        increment_subtree_size(child_job.subtree_size)
        increment_finished_subtree_size(child_job.finished_subtree_size)
      end

      def workflow
        Workflow.find(root)
      end


      ### Status get/set

      def status
        case self[STATUS_FIELD]
        when STATUS_ENQUEUED
          :enqueued
        when STATUS_RUNNING
          :running
        when STATUS_COMPLETE
          :complete
        when STATUS_REQUEUED
          :requeued
        when STATUS_FAILED
          :failed
        else
          :unknown
        end
      end

      def update_status(new_status)
        old_status = status
        return if new_status == old_status

        case new_status
        when :enqueued
          s_val, t_field = STATUS_ENQUEUED, ENQUEUED_AT_FIELD
        when :running
          s_val, t_field = STATUS_RUNNING, RUN_AT_FIELD
        when :complete
          s_val, t_field = STATUS_COMPLETE, COMPLETED_AT_FIELD
        when :requeued
          s_val, t_field = STATUS_REQUEUED, nil
        when :failed
          s_val, t_field = STATUS_FAILED, COMPLETED_AT_FIELD
        end

        self[STATUS_FIELD] = s_val
        self[t_field] = Time.now.to_f.to_s if t_field
        increment_finished_subtree_size if [:failed, :complete].include?(new_status)

        Sidekiq::Hierarchy.publish(Notifications::JOB_UPDATE, self, new_status, old_status)
      end

      # Status update: mark as enqueued (step 1)
      def enqueue!
        update_status :enqueued
      end

      def enqueued?
        status == :enqueued
      end

      def enqueued_at
        if t = self[ENQUEUED_AT_FIELD]
          Time.at(t.to_f)
        end
      end

      # Status update: mark as running (step 2)
      def run!
        update_status :running
      end

      def running?
        status == :running
      end

      def run_at
        if t = self[RUN_AT_FIELD]
          Time.at(t.to_f)
        end
      end

      # Status update: mark as complete (step 3)
      def complete!
        update_status :complete
      end

      def complete?
        status == :complete
      end

      def complete_at
        if complete? && t = self[COMPLETED_AT_FIELD]
          Time.at(t.to_f)
        end
      end

      def requeue!
        update_status :requeued
      end

      def requeued?
        status == :requeued
      end

      def fail!
        update_status :failed
      end

      def failed?
        status == :failed
      end

      def failed_at
        if failed? && t = self[COMPLETED_AT_FIELD]
          Time.at(t.to_f)
        end
      end

      def finished?
        [:failed, :complete].include?(status)  # two terminal states
      end

      def finished_at
        if t = self[COMPLETED_AT_FIELD]
          Time.at(t.to_f)
        end
      end


      ### Serialisation

      def as_json(options={})
        {k: info['class'], c: children.sort_by {|c| c.info['class']}.map(&:as_json)}
      end


      ### Redis backend

      def redis_job_hkey
        "hierarchy:job:#{jid}"
      end

      def redis_children_lkey
        "#{redis_job_hkey}:children"
      end
    end
  end
end
