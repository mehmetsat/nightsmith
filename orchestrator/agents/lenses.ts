// The loop, not the model, picks each research round's angle. A model choosing its own
// angle drifts back to the same one every time; a fixed rotation plus a random draw does not.

export const LENSES = [
  "One specific user: a support engineer who screenshots bugs, logs and dashboards all day and must find them again weeks later.",
  "User complaints: what people actually hate about screenshot tools and clipboard managers today (forums, Reddit, app reviews, issue trackers).",
  "A far-away domain (see the forced analogy below): how that field keeps, labels and re-finds visual material.",
  "Academic HCI research on re-finding, personal information management and visual search.",
  "Software history: tools from the 1980s to 2000s that solved capture and re-finding differently, and why they faded.",
  "A hard constraint: the whole app must work keyboard-only, with no mouse or trackpad at all.",
  "A physical-world analogy: how people keep and find paper, photos, receipts and notes on a desk.",
  "The first 60 seconds: first launch, empty states, the first capture, the first moment of delight.",
  "A power user at scale: 50,000 captures over five years. What breaks, what becomes valuable?",
  "Privacy and trust: what users fear about an app that keeps everything on their screen, and how the best tools earn trust.",
  "Motion and feel: how the best interfaces in any field (games, cars, cameras, film editing) use motion to explain state.",
  "Accessibility: VoiceOver users, reduced motion, low vision, motor impairments.",
];

export const DOMAINS = [
  "museum archives and collection management", "air traffic control strips", "darkroom photography and contact sheets",
  "restaurant kitchens and mise en place", "library card catalogs", "music sampling on hardware samplers",
  "court stenography", "film editing bins", "field biology notebooks", "trading floor terminals",
  "sports video analysis", "laboratory notebooks", "radio DJ cart machines", "medical imaging archives",
  "detective case boards", "fashion moodboards", "geology core sample libraries", "subway map design",
  "video game inventories", "postal sorting", "herbarium specimen sheets", "chess opening databases",
  "comic book lettering", "architects' flat files", "seed banks", "air crash investigation",
  "newspaper photo desks", "stamp collecting albums", "mountain rescue logbooks", "theatre prompt books",
  "watchmaking parts trays", "wine cellar records", "orchestra music libraries", "police evidence lockers",
  "botanical garden labels", "satellite image analysis", "lighthouse logs", "typesetting job cases",
];

export const DESIGN_CONSTRAINTS = [
  "Typography does almost all the work. Images are small; type sets the hierarchy.",
  "Nearly no colour: one accent at most, everything else greys tinted towards it.",
  "Motion explains every state change; nothing appears or disappears without a reason you can see.",
  "Dense and information-rich, like a professional tool. No wasted space.",
  "Spacious and calm, like a gallery. Few things on screen, each given room.",
  "Physical and tactile: things have weight, depth and material.",
  "Keyboard-first: every visible element shows how to reach it from the keyboard.",
  "Time is the main axis: the layout itself shows when things happened.",
];

/** Small seeded RNG (mulberry32) so a run's draws can be repeated from its id. */
export function rng(seedText: string) {
  let a = [...seedText].reduce((h, c) => Math.imul(h ^ c.charCodeAt(0), 2654435761) >>> 0, 1779033703);
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function pick<T>(list: T[], r: () => number, n = 1): T[] {
  const pool = [...list];
  const out: T[] = [];
  while (out.length < n && pool.length) out.push(pool.splice(Math.floor(r() * pool.length), 1)[0]);
  return out;
}
