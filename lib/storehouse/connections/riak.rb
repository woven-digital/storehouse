require 'riak'
require 'cgi'

module Storehouse
  module Connections
    class Riak

      def initialize(spec)
        @spec           = spec || {}
        @bucket_name    = spec.delete('bucket') || 'page_cache'
        @bucket         = ::Riak::Client.new(@spec).bucket(@bucket_name)
      end

      def read(path, skip_escape = false)
        path = storage_path(path, skip_escape)

        object = begin
          @bucket.get(path)
        rescue Exception => e
          if e.message =~ /404/
            nil
          else
            raise e
          end
        end

        return {} unless riak_object?(object)

        expires_at = value_from_index(object, 'expires_at_int')
        created_at = value_from_index(object, 'created_at_int')

        data = object.data
        data.merge!('expires_at' => expires_at, 'created_at' => created_at)

        data
      end

      def write(path, hash, skip_escape = false)
        path = storage_path(path, skip_escape)
        object = @bucket.get_or_new(path)

        return nil unless riak_object?(object)

        object.content_type = 'application/json'
        object.data = hash

        created_at = hash.delete('created_at').to_i
        expires_at = hash.delete('expires_at').to_i

        set_index(object, 'created_at_int', created_at)
        set_index(object, 'expires_at_int', expires_at)

        object.store
      end

      def delete(path, skip_escape = false)
        path = storage_path(path, skip_escape)
        hash = read(path, true)
        @bucket.delete(path)
        hash
      end

      def expire(path, skip_escape = false)
        path = storage_path(path, skip_escape)
        hash = read(path, true)
        hash['expires_at'] = Time.now.to_i
        write(path, hash, true)
      end

      def clean!(namespace = nil)
        chunked(namespace) do |key|
          object = read(key)
          if object.expired?
            delete(key, true)
          else
            expire(key, true)
          end
        end
      end
      alias_method :expire_all!, :clean!

      def clear!(namespace = nil)
        chunked(namespace) do |key|
          delete(key, true)
        end
      end


      protected

      def chunked(namespace = nil)

        namespace = storage_path(namespace)

        t = Time.now.to_i - 60*24*60*60 # 2 months ago
        t0 = Time.now.to_i 

        clearing_delta = 24*60*60 # one day
        cnt = 0

        # chunked sets of keys based on created at timestamp
        begin

          t1 = t0 - clearing_delta
          t1 = [t1, t].max

          cnt = 0
          @bucket.get_index('created_at_int', t0.to_i...t1.to_i).each do |k|
            if !namespace || k =~ /^#{namespace}/
              yield k
              cnt += 1
            end
          end

          t0 -= clearing_delta

        end while(t < t0 && cnt > 0)
      end

      def set_index(object, name, value)
        object.indexes[name] = Set.new([value])
      end


      def value_from_index(object, name)
        val = object.indexes[name]
        val.respond_to?(:first) ? val.first : val # might come back as a Set
      end

      def riak_object?(object)
        object.is_a?(::Riak::RObject)
      end

      def storage_path(path, skip_escape = false)
        return nil if path.nil?
        return path if skip_escape
        CGI.escape(path)
      end

    end
  end
end