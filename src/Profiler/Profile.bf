using System;
using System.Collections;

namespace Nova.Profiler;

class Profile : IEnumerable<Entry> {
	private List<Entry> entries = new .() ~ DeleteContainerAndItems!(_);

	private this() {}

	public List<Entry>.Enumerator GetEnumerator() => entries.GetEnumerator();

	public static Profile Parse() {
		Profile data = new .();
		List<Entry> callStack = scope .();

		for (let event in EventQueue.Events) {
			if (event.type == .Begin) {
				Location location = Locations.Get((.) event.data);
	
				if (callStack.IsEmpty) {
					Entry entry = new [Friend].(location);
	
					data.entries.Add(entry);
					callStack.Add(entry);
				}
				else {
					Entry parent = callStack.Back;
					Entry entry = parent.GetChild(location);
	
					if (entry == null) {
						entry = new [Friend].(location);
						parent.[Friend]AddChild(entry);
					}

					callStack.Add(entry);
				}
			}
			else {
				Entry entry = callStack.PopBack();
				entry.[Friend]AddCall((.) (event.data * 10));
			}
		}

		return data;
	}

	public class Entry : IEnumerable<Entry> {
		public Location location;

		public int calls;
		public TimeSpan total;

		private Dictionary<Location, Entry> children ~ DeleteDictionaryAndValues!(_);

		private this(Location location) {
			this.location = location;
		}

		public TimeSpan Average => (.) (total.Ticks / (int64) calls);

		public Entry GetChild(Location location) {
			return children?.GetValueOrDefault(location);
		}

		private void AddChild(Entry entry) {
			if (children == null) children = new .();
			children[entry.location] = entry;
		}

		private void AddCall(TimeSpan time) {
			calls++;
			total += time;
		}

		public ChildrenEnumerator GetEnumerator() => .(children);

		public struct ChildrenEnumerator : IEnumerator<Entry> {
			private Dictionary<Location, Entry>.ValueEnumerator children;
			private bool exists;

			public this(Dictionary<Location, Entry> children) {
				if (children == null) {
					this.children = default;
					this.exists = false;
				}
				else {
					this.children = children.Values;
					this.exists = true;
				}
			}

			public Result<Entry> GetNext() mut {
				if (exists) return children.GetNext();
				return .Err;
			}
		}
	}
}