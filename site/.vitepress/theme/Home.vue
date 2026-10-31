<script setup lang="ts">
import { withBase } from 'vitepress'

const releases = 'https://github.com/Nagilordy/Frame/releases'
// Until the first full (non-test) release is out, both buttons open the Releases page.
// After that they can point straight at the files:
//   releases/latest/download/FrameSetup.exe and releases/latest/download/Frame-x86_64.AppImage
const windows = releases
const linux = releases

const features = [
  { icon: '🎮', title: 'Made for controllers', text: 'PlayStation, Xbox and Steam controllers out of the box, with a button guide that matches yours. Mouse and keyboard work everywhere too.' },
  { icon: '✨', title: 'Best-quality playback', text: 'The original file, straight from your server: 4K, HDR, Dolby Vision, TrueHD and Atmos. Falls back to the server only when needed.' },
  { icon: '🍿', title: 'Watch together', text: 'Start a party, friends get an invite. Pause, skip or go back and it happens for everyone, episode after episode.' },
  { icon: '📺', title: 'Feels like a console', text: 'Full-screen artwork, big readable menus and panels that slide up from the bottom. Made to be read from the couch.' },
  { icon: '🔖', title: 'Remembers you', text: 'Audio and subtitles per show, where you stopped, your next episode, all synced with Jellyfin.' },
  { icon: '🏠', title: 'Your library, your server', text: 'Nothing to migrate: Frame works with your existing Jellyfin server and users, alongside the official apps.' },
]
</script>

<template>
  <div class="fh">
    <div class="glow" aria-hidden="true" />
    <section class="hero">
      <img class="mark" :src="withBase('/mark.svg')" alt="" width="88" height="88">
      <h1>Your Jellyfin library,<br>the way a console would show it.</h1>
      <p class="lead">Frame is a couch-first app for Jellyfin on Linux and Windows. Made for a controller, great with a mouse.</p>
      <div class="actions">
        <a class="btn primary" :href="windows">Download for Windows</a>
        <a class="btn" :href="linux">Download for Linux</a>
        <a class="btn" :href="withBase('/guide/getting-started')">Read the guide</a>
      </div>
      <p class="note">Version 0.3 · free · needs a Jellyfin server</p>
    </section>

    <section class="shot">
      <img :src="withBase('/shots/home.jpg')" alt="Frame's Home screen: full-screen artwork, the show's logo, Resume and Watch together, Continue watching below">
    </section>

    <section class="features">
      <article v-for="f in features" :key="f.title">
        <span class="icon">{{ f.icon }}</span>
        <h3>{{ f.title }}</h3>
        <p>{{ f.text }}</p>
      </article>
    </section>

    <section class="more">
      <figure>
        <img :src="withBase('/shots/player.jpg')" alt="The player with its see-through bar: Audio, Subtitles, Playback and Info">
        <figcaption>The player shows what's playing at a glance.</figcaption>
      </figure>
      <figure>
        <img :src="withBase('/shots/watch-party.jpg')" alt="Starting a watch party">
        <figcaption>Watch parties: anything you play opens for everyone.</figcaption>
      </figure>
      <figure>
        <img :src="withBase('/shots/show-page.jpg')" alt="A show page with the selected episode's full summary above the episode row">
        <figcaption>Show pages: pick an episode and read its whole summary.</figcaption>
      </figure>
      <figure>
        <img :src="withBase('/shots/movie-page.jpg')" alt="A movie page with logo, details, summary and cast">
        <figcaption>Movie pages: everything about the film, one press from playing.</figcaption>
      </figure>
      <figure>
        <img :src="withBase('/shots/library.jpg')" alt="A library of anime posters">
        <figcaption>Libraries made to browse with a controller.</figcaption>
      </figure>
      <figure>
        <img :src="withBase('/shots/sort-filter.jpg')" alt="Sort and filter sheet">
        <figcaption>Sort &amp; filter in one sheet.</figcaption>
      </figure>
    </section>

    <section class="cta">
      <h2>Try it on your couch tonight.</h2>
      <div class="actions">
        <a class="btn primary" :href="windows">Download for Windows</a>
        <a class="btn" :href="linux">Download for Linux</a>
      </div>
      <p class="note">Found a problem? <a href="https://github.com/Nagilordy/Frame/issues/new?template=bug_report.yml">Report a bug</a> · Have an idea? <a href="https://github.com/Nagilordy/Frame/issues/new?template=feature_request.yml">Suggest it</a></p>
    </section>
  </div>
</template>

<style scoped>
.fh { position: relative; overflow: hidden; padding: 0 24px 80px; }
.glow { position: absolute; left: 0; right: 0; top: -64px; height: 1100px; pointer-events: none;
  background: radial-gradient(ellipse at 50% 35%, rgba(244,245,247,0.10) 0%, rgba(13,14,16,0) 60%); }
.hero { position: relative; text-align: center; padding: 96px 0 0; }
.mark { margin: 0 auto; }
h1 { margin: 18px auto 0; font-family: Sora, sans-serif; font-weight: 700; font-size: clamp(36px, 5vw, 64px); line-height: 1.12; letter-spacing: -0.01em; color: #f4f5f7; max-width: 1100px; }
.lead { margin: 22px auto 0; font-size: clamp(18px, 2vw, 22px); line-height: 1.5; color: #d3d8e0; max-width: 760px; }
.actions { margin-top: 34px; display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; }
.btn { height: 52px; padding: 0 26px; border-radius: 999px; display: inline-flex; align-items: center; font-size: 17px; font-weight: 700; background: rgba(244,245,247,0.08); color: #f4f5f7; text-decoration: none; transition: background .15s, transform .15s; }
.btn:hover { background: rgba(244,245,247,0.14); transform: translateY(-1px); }
.btn.primary { background: #e4a15a; color: #0d0e10; }
.btn.primary:hover { background: #eab275; }
.note { margin: 16px 0 0; font-size: 14px; color: #8e97a6; }
.note a { color: #d3d8e0; text-decoration: underline; text-underline-offset: 3px; }
.shot { position: relative; max-width: 1232px; margin: 64px auto 0; }
.shot img { width: 100%; display: block; border-radius: 18px; box-shadow: 0 0 0 1px rgba(244,245,247,0.08), 0 40px 100px rgba(0,0,0,0.6); }
.features { max-width: 1232px; margin: 100px auto 0; display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; }
.features article { background: #16181c; border: 1px solid rgba(244,245,247,0.08); border-radius: 16px; padding: 28px; }
.features .icon { width: 48px; height: 48px; border-radius: 12px; background: rgba(244,245,247,0.08); display: flex; align-items: center; justify-content: center; font-size: 24px; }
.features h3 { margin: 16px 0 0; font-family: 'Hanken Grotesk', sans-serif; font-size: 19px; font-weight: 700; color: #f4f5f7; }
.features p { margin: 10px 0 0; font-size: 15px; line-height: 1.6; color: #8e97a6; }
.more { max-width: 1232px; margin: 80px auto 0; display: grid; grid-template-columns: repeat(2, 1fr); gap: 28px 20px; }
.more figure { margin: 0; }
.more img { width: 100%; display: block; border-radius: 12px; box-shadow: 0 0 0 1px rgba(244,245,247,0.06); }
.more figcaption { margin-top: 12px; font-size: 15px; color: #8e97a6; }
.cta { text-align: center; margin: 110px auto 0; }
.cta h2 { margin: 0; border: 0; padding: 0; font-family: Sora, sans-serif; font-size: clamp(28px, 3.5vw, 40px); color: #f4f5f7; }
@media (max-width: 900px) {
  .features { grid-template-columns: 1fr; }
  .more { grid-template-columns: 1fr; }
  .hero { padding-top: 56px; }
}
</style>
