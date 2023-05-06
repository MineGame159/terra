using System;
using System.Collections;

namespace Nova.Profiler;

enum EventType {
	Begin,
	End
}

struct Event {
	public EventType type;
	public int64 data;
}

static class EventQueue {
	private const int PAGE_SIZE = 8192;

	private static List<Page> pages = new .() ~ DeleteContainerAndItems!(_);
	
	public static void Begin(int64 data) {
		Event* event = GetEvent();

		event.type = .Begin;
		event.data = data;
	}
	
	public static void End(int64 data) {
		Event* event = GetEvent();

		event.type = .End;
		event.data = data;
	}

	public static EventEnumerator Events => .();

	private static Event* GetEvent() {
		Page page;

		mixin NewPage() {
			page = new .();
			pages.Add(page);
		}

		if (pages.IsEmpty) {
			NewPage!();
		}
		else {
			page = pages.Back;
			if (page.IsFull) NewPage!();
		}

		return page.GetEvent();
	}

	class Page {
		public Event* events;
		public int count;

		[AllowAppend]
		public this() {
			Event* events = append Event[PAGE_SIZE]*;

			this.events = events;
		}

		public bool IsFull => count >= PAGE_SIZE;

		public Event* GetEvent() => &events[count++];
	}

	public struct EventEnumerator : IEnumerator<Event> {
		private int pageI;
		private int eventI;

		public Result<Event> GetNext() mut {
			if (pageI >= pages.Count) return .Err;

			Page page = pages[pageI];

			if (eventI >= page.count) {
				pageI++;
				eventI = 0;

				return GetNext();
			}

			return page.events[eventI++];
		}
	}
}