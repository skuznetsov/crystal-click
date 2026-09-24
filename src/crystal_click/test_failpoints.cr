{% if flag?(:crystal_click_test_failpoints) %}
  module CrystalClick
    module TestFailpoint
      def self.hit(name : String) : Nil
        return unless ENV["CRYSTAL_CLICK_TEST_FAILPOINT"]? == name

        ready_path = ENV["CRYSTAL_CLICK_TEST_FAILPOINT_READY"]? || raise "missing test failpoint ready path"
        File.write(ready_path, name)
        loop do
          sleep 60.seconds
        end
      end
    end
  end
{% end %}
