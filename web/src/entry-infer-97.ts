// infer.imdusd.com/97/: INFER 97 in a frame. X shows the page inside a post (a player card); PUSH START plays it
// with sound, which a framed page may only do after a click.
import "./infer/infer97.css";

const film = document.getElementById("film") as HTMLVideoElement;
const start = document.getElementById("start") as HTMLButtonElement;
start.addEventListener("click", () => {
  film.muted = false;
  void film.play();
});
film.addEventListener("play", () => (start.hidden = true));
film.addEventListener("pause", () => (start.hidden = film.ended));
