class PrefixOracle
  def initialize
    @events = {}
  end

  def receive(sequence, delta)
    if @events.key?(sequence)
      return { "error" => "conflict", "seq" => sequence } unless @events.fetch(sequence) == delta

      status = "duplicate"
    else
      @events[sequence] = delta
      status = "accepted"
    end
    { "status" => status, "seq" => sequence }.merge(state)
  end

  def state
    prefix = @events.sort.each_with_index.take_while do |(sequence, _delta), index|
      sequence == index + 1
    end
    { "cursor" => prefix.size, "balance" => prefix.sum { |(_sequence, delta), _index| delta } }
  end
end
