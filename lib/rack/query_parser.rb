# frozen_string_literal: true

require_relative 'bad_request'
require 'uri'

module Rack
  class QueryParser
    DEFAULT_SEP = /& */n
    COMMON_SEP = { ";" => /; */n, ";," => /[;,] */n, "&" => /& */n }

    # ParameterTypeError is the error that is raised when incoming structural
    # parameters (parsed by parse_nested_query) contain conflicting types.
    class ParameterTypeError < TypeError
      include BadRequest
    end

    # InvalidParameterError is the error that is raised when incoming structural
    # parameters (parsed by parse_nested_query) contain invalid format or byte
    # sequence.
    class InvalidParameterError < ArgumentError
      include BadRequest
    end

    # ParamsTooDeepError is the error that is raised when params are recursively
    # nested over the specified limit.
    class ParamsTooDeepError < RangeError
      include BadRequest
    end

    def self.make_default(param_depth_limit)
      new Params, param_depth_limit
    end

    attr_reader :param_depth_limit

    def initialize(params_class, param_depth_limit)
      @params_class = params_class
      @param_depth_limit = param_depth_limit
    end

    # Originally stolen from Mongrel, now with some modifications:
    # Parses a query string by breaking it up at the '&'.  You can also use this
    # to parse cookies by changing the characters used in the second parameter
    # (which defaults to '&').
    #
    # Returns an array of 2-element arrays, where the first element is the
    # key and the second element is the value.
    def split_query(qs, separator = nil, &unescaper)
      pairs = []

      if qs && !qs.empty?
        unescaper ||= method(:unescape)

        qs.split(separator ? (COMMON_SEP[separator] || /[#{separator}] */n) : DEFAULT_SEP).each do |p|
          next if p.empty?
          pair = p.split('=', 2).map!(&unescaper)
          pair << nil if pair.length == 1
          pairs << pair
        end
      end

      pairs
    rescue ArgumentError => e
      raise InvalidParameterError, e.message, e.backtrace
    end

    # Parses a query string by breaking it up at the '&'.  You can also use this
    # to parse cookies by changing the characters used in the second parameter
    # (which defaults to '&').
    #
    # Returns a hash where each value is a string (when a key only appears once)
    # or an array of strings (when a key appears more than once).
    def parse_query(qs, separator = nil, &unescaper)
      params = make_params

      split_query(qs, separator, &unescaper).each do |k, v|
        if cur = params[k]
          if cur.class == Array
            params[k] << v
          else
            params[k] = [cur, v]
          end
        else
          params[k] = v
        end
      end

      params.to_h
    end

    # parse_nested_query expands a query string into structural types. Supported
    # types are Arrays, Hashes and basic value types. It is possible to supply
    # query strings with parameters of conflicting types, in this case a
    # ParameterTypeError is raised. Users are encouraged to return a 400 in this
    # case.
    def parse_nested_query(qs, separator = nil)
      params = make_params

      split_query(qs, separator).each do |k, v|
        _normalize_params(params, k, v, 0)
      end

      params.to_h
    end

    # normalize_params recursively expands parameters into structural types. If
    # the structural types represented by two different parameter names are in
    # conflict, a ParameterTypeError is raised.  The depth argument is deprecated
    # and should no longer be used, it is kept for backwards compatibility with
    # earlier versions of rack.
    def normalize_params(params, name, v, _depth=nil)
      _normalize_params(params, name, v, 0)
    end

    # This value is used by default when a parameter is missing (nil). This
    # usually happens when a parameter is specified without an `=value` part.
    # The default value is an empty string, but this can be overridden by
    # subclasses.
    def missing_value
      String.new
    end

    private def _normalize_params(params, name, v, depth)
      raise ParamsTooDeepError if depth >= param_depth_limit

      if !name
        # nil name, treat same as empty string (required by tests)
        k = after = ''
      elsif depth == 0
        # Start of parsing, don't treat [] or [ at start of string specially
        if start = name.index('[', 1)
          # Start of parameter nesting, use part before brackets as key
          k = name[0, start]
          after = name[start, name.length]
        else
          # Plain parameter with no nesting
          k = name
          after = ''
        end
      elsif name.start_with?('[]')
        # Array nesting
        k = '[]'
        after = name[2, name.length]
      elsif name.start_with?('[') && (start = name.index(']', 1))
        # Hash nesting, use the part inside brackets as the key
        k = name[1, start-1]
        after = name[start+1, name.length]
      else
        # Probably malformed input, nested but not starting with [
        # treat full name as key for backwards compatibility.
        k = name
        after = ''
      end

      return if k.empty?

      v ||= missing_value

      if after == ''
        if k == '[]' && depth != 0
          return [v]
        else
          params[k] = v
        end
      elsif after == "["
        params[name] = v
      elsif after == "[]"
        params[k] ||= []
        raise ParameterTypeError, "expected Array (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Array)
        params[k] << v
      elsif after.start_with?('[]')
        # Recognize x[][y] (hash inside array) parameters
        unless after[2] == '[' && after.end_with?(']') && (child_key = after[3, after.length-4]) && !child_key.empty? && !child_key.index('[') && !child_key.index(']')
          # Handle other nested array parameters
          child_key = after[2, after.length]
        end
        params[k] ||= []
        raise ParameterTypeError, "expected Array (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Array)
        if params_hash_type?(params[k].last) && !params_hash_has_key?(params[k].last, child_key)
          _normalize_params(params[k].last, child_key, v, depth + 1)
        else
          params[k] << _normalize_params(make_params, child_key, v, depth + 1)
        end
      else
        params[k] ||= make_params
        raise ParameterTypeError, "expected Hash (got #{params[k].class.name}) for param `#{k}'" unless params_hash_type?(params[k])
        params[k] = _normalize_params(params[k], after, v, depth + 1)
      end

      params
    end

    def make_params
      @params_class.new
    end

    def new_depth_limit(param_depth_limit)
      self.class.new @params_class, param_depth_limit
    end

    private

    def params_hash_type?(obj)
      obj.kind_of?(@params_class)
    end

    def params_hash_has_key?(hash, key)
      return false if /\[\]/.match?(key)

      key.split(/[\[\]]+/).inject(hash) do |h, part|
        next h if part == ''
        return false unless params_hash_type?(h) && h.key?(part)
        h[part]
      end

      true
    end

    def unescape(string, encoding = Encoding::UTF_8)
      URI.decode_www_form_component(string, encoding)
    end

    class Params < Hash
      alias_method :to_params_hash, :to_h
    end
  end
end
