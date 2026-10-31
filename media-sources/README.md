# App icon

`icon.png` is the 1024px RGBA master for the illustrated app icon. The artwork
was created with the built-in imagegen tool using the previous photographic
icon as its subject and composition reference. It was then resampled to 1024px
with macOS `sips`.

Run `python3 media-sources/generate-icon.py` on macOS to export every asset-catalog
size from the master. This does not modify the master. No third-party Python
packages are needed.

## Image generation prompt

Use case: style-transfer. Asset type: production macOS app icon for RepoMen,
square 1024 x 1024. Input image: the existing local app icon is the reference for
subject, face, pose and composition. Create a new original drawn interpretation
of that icon: the same recognizable front-facing adult man, short dark brown
hair, blue-green eyes, serious expression, reclining against a blue futuristic
medical chair, with small silver electrode clamps at both temples and a few
dark cables near his shoulders. Preserve the head-and-shoulders composition and
identity of the reference. Style: sophisticated hand-drawn graphic illustration,
clean expressive dark ink contours, simplified sculptural planes, restrained
screenprint texture, warm copper/peach skin highlights against deep midnight navy
and petrol teal equipment, pale icy cyan edge light, beautifully balanced graphic
shapes. Emphasize the face and eyes, reduce tiny mechanical details so the
portrait works in a small Dock icon. The result should feel like a carefully
drawn cinematic poster distilled into a premium native Mac icon. Format: one
rounded-square macOS icon tile centered within a genuinely transparent 1024
square canvas. Tile occupies approximately x=100..924 and y=100..924 with corner
radius about 186, matching the reference's transparent outer margins. Art fills
and is clipped inside that tile, including the bottom of the shoulders. No text,
no lettering, no border frame, no extra badges, no photorealism, no mockup, no
outside background. Deliver only the finished icon.
