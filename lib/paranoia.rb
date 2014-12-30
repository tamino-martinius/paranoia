require 'active_record' unless defined? ActiveRecord

module Paranoia
  @@default_sentinel_value = nil

  # Change default_sentinel_value in a rails initilizer
  def self.default_sentinel_value=(val)
    @@default_sentinel_value = val
  end

  def self.default_sentinel_value
    @@default_sentinel_value
  end

  def self.included(klazz)
    klazz.extend Query
    klazz.extend Callbacks
  end

  module PreloaderAssociation
    def self.included(base)
      base.class_eval do
        def build_scope_with_deleted
          scope = build_scope_without_deleted
          scope = scope.with_deleted if options[:with_deleted] && klass.respond_to?(:with_deleted)
          scope
        end

        alias_method_chain :build_scope, :deleted
      end
    end
  end

  module Association
    def self.included(base)
      base.extend ClassMethods
      class << base
        alias_method_chain :belongs_to, :deleted
      end
    end

    module ClassMethods

      def belongs_to_with_deleted(target, scope = nil, options = {})
        with_deleted = (scope.is_a?(Hash) ? scope : options).delete(:with_deleted)
        result = belongs_to_without_deleted(target, scope, options)

        if with_deleted
          result[target].options[:with_deleted] = with_deleted
          unless method_defined? "#{target}_with_unscoped"
            class_eval <<-RUBY, __FILE__, __LINE__
              def #{target}_with_unscoped(*args)
                association = association(:#{target})
                return nil if association.options[:polymorphic] && association.klass.nil?
                return #{target}_without_unscoped(*args) unless association.klass.paranoid?
                association.klass.with_deleted.scoping { #{target}_without_unscoped(*args) }
              end
              alias_method_chain :#{target}, :unscoped
            RUBY
          end
        end

        result
      end
    end
  end

  module Query
    def paranoid? ; true ; end

    def with_deleted
      if ActiveRecord::VERSION::STRING >= "4.1"
        unscope where: paranoia_column
      else
        all.tap { |x| x.default_scoped = false }
      end
    end

    def only_deleted
      with_deleted.where.not(paranoia_column => paranoia_sentinel_value)
    end
    alias :deleted :only_deleted

    def restore(id, opts = {})
      Array(id).flatten.map { |one_id| only_deleted.find(one_id).restore!(opts) }
    end
  end

  module Callbacks
    def self.extended(klazz)
      klazz.define_callbacks :restore

      klazz.define_singleton_method("before_restore") do |*args, &block|
        set_callback(:restore, :before, *args, &block)
      end

      klazz.define_singleton_method("around_restore") do |*args, &block|
        set_callback(:restore, :around, *args, &block)
      end

      klazz.define_singleton_method("after_restore") do |*args, &block|
        set_callback(:restore, :after, *args, &block)
      end

      klazz.define_callbacks :really_destroy

      klazz.define_singleton_method("before_really_destroy") do |*args, &block|
        set_callback(:really_destroy, :before, *args, &block)
      end

      klazz.define_singleton_method("around_really_destroy") do |*args, &block|
        set_callback(:really_destroy, :around, *args, &block)
      end

      klazz.define_singleton_method("after_really_destroy") do |*args, &block|
        set_callback(:really_destroy, :after, *args, &block)
      end
    end
  end

  def destroy
    callbacks_result = transaction do
      run_callbacks(:destroy) do
        touch_paranoia_column
      end
    end
    callbacks_result ? self : false
  end

  # As of Rails 4.1.0 +destroy!+ will no longer remove the record from the db
  # unless you touch the paranoia column before.
  # We need to override it here otherwise children records might be removed
  # when they shouldn't
  if ActiveRecord::VERSION::STRING >= "4.1"
    def destroy!
      destroyed? ? super : destroy || raise(ActiveRecord::RecordNotDestroyed)
    end
  end

  def delete
    return if new_record?
    touch_paranoia_column(false)
  end

  def restore!(opts = {})
    self.class.transaction do
      run_callbacks(:restore) do
        # Fixes a bug where the build would error because attributes were frozen.
        # This only happened on Rails versions earlier than 4.1.
        noop_if_frozen = ActiveRecord.version < Gem::Version.new("4.1")
        if (noop_if_frozen && !@attributes.frozen?) || !noop_if_frozen
          write_attribute paranoia_column, paranoia_sentinel_value
          update_column paranoia_column, paranoia_sentinel_value
        end
        restore_associated_records if opts[:recursive]
      end
    end

    self
  end
  alias :restore :restore!

  def destroyed?
    send(paranoia_column) != paranoia_sentinel_value
  end
  alias :deleted? :destroyed?

  private

  # touch paranoia column.
  # insert time to paranoia column.
  # @param with_transaction [Boolean] exec with ActiveRecord Transactions.
  def touch_paranoia_column(with_transaction=false)
    # This method is (potentially) called from really_destroy
    # The object the method is being called on may be frozen
    # Let's not touch it if it's frozen.
    unless self.frozen?
      if with_transaction
        with_transaction_returning_status { touch(paranoia_column) }
      else
        touch(paranoia_column)
      end
    end
  end

  # restore associated records that have been soft deleted when
  # we called #destroy
  def restore_associated_records
    destroyed_associations = self.class.reflect_on_all_associations.select do |association|
      association.options[:dependent] == :destroy
    end

    destroyed_associations.each do |association|
      association_data = send(association.name)

      unless association_data.nil?
        if association_data.paranoid?
          if association.collection?
            association_data.only_deleted.each { |record| record.restore(:recursive => true) }
          else
            association_data.restore(:recursive => true)
          end
        end
      end

      if association_data.nil? && association.macro.to_s == "has_one"
        association_class_name = association.options[:class_name].present? ? association.options[:class_name] : association.name.to_s.camelize
        association_foreign_key = association.options[:foreign_key].present? ? association.options[:foreign_key] : "#{self.class.name.to_s.underscore}_id"
        if Object.const_get(association_class_name).paranoid?
          Object.const_get(association_class_name).only_deleted.where(association_foreign_key, self.id).first.try(:restore, recursive: true)
        end
      end
    end

    clear_association_cache if destroyed_associations.present?
  end
end



class ActiveRecord::Base

  def self.acts_as_paranoid(options={})
    alias :destroy! :destroy
    alias :delete! :delete

    def really_destroy!
      run_callbacks(:really_destroy) do
        dependent_reflections = self.class.reflections.select do |name, reflection|
          reflection.options[:dependent] == :destroy
        end
        if dependent_reflections.any?
          dependent_reflections.each do |name, _|
            associated_records = self.send(name)
            # has_one association can return nil
            if associated_records && associated_records.respond_to?(:with_deleted)
              # Paranoid models will have this method, non-paranoid models will not
              associated_records.with_deleted.each(&:really_destroy!)
              self.send(name).reload
            elsif associated_records && !associated_records.respond_to?(:each) # single record
              associated_records.really_destroy!
            end
          end
        end

        touch_paranoia_column if ActiveRecord::VERSION::STRING >= "4.1"
        destroy!
      end
    end

    include Paranoia
    class_attribute :paranoia_column, :paranoia_sentinel_value

    self.paranoia_column = options[:column] || :deleted_at
    self.paranoia_sentinel_value = options.fetch(:sentinel_value) { Paranoia.default_sentinel_value }
    default_scope { where(paranoia_column => paranoia_sentinel_value) }

    before_restore {
      self.class.notify_observers(:before_restore, self) if self.class.respond_to?(:notify_observers)
    }
    after_restore {
      self.class.notify_observers(:after_restore, self) if self.class.respond_to?(:notify_observers)
    }
  end

  # Please do not use this method in production.
  # Pretty please.
  def self.I_AM_THE_DESTROYER!
    # TODO: actually implement spelling error fixes
    puts %Q{
      Sharon: "There should be a method called I_AM_THE_DESTROYER!"
      Ryan:   "What should this method do?"
      Sharon: "It should fix all the spelling errors on the page!"
}
  end

  def self.paranoid? ; false ; end
  def paranoid? ; self.class.paranoid? ; end

  # Override the persisted method to allow for the paranoia gem.
  # If a paranoid record is selected, then we only want to check
  # if it's a new record, not if it is "destroyed".
  def persisted?
    paranoid? ? !new_record? : super
  end

  private

  def paranoia_column
    self.class.paranoia_column
  end

  def paranoia_sentinel_value
    self.class.paranoia_sentinel_value
  end
end

ActiveRecord::Base.send :include, Paranoia::Association if ActiveRecord::VERSION::STRING >= "4.1"
ActiveRecord::Associations::Preloader::Association.send :include, Paranoia::PreloaderAssociation if ActiveRecord::VERSION::STRING >= "4.1"

require 'paranoia/rspec' if defined? RSpec
