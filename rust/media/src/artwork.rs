//! Cover-art handling: embedded pictures (lofty) and the app's cleanup
//! pipeline — trim black/flat letterbox bars, centre-crop to square,
//! downscale, re-encode as JPEG.

use image::{DynamicImage, GenericImageView, imageops::FilterType};
use std::path::Path;

/// First embedded picture (front cover preferred) larger than 500 bytes.
pub fn embedded(path: &Path) -> Option<Vec<u8>> {
    use lofty::file::TaggedFileExt;
    use lofty::picture::PictureType;
    let f = crate::tags::open_tagged(path)?;
    let pics: Vec<&lofty::picture::Picture> = f.tags().iter().flat_map(|t| t.pictures()).filter(|p| p.data().len() > 500).collect();
    pics.iter().find(|p| p.pic_type() == PictureType::CoverFront).or(pics.first()).map(|p| p.data().to_vec())
}

/// Bounds of the content inside dark, flat letterbox/pillarbox bars,
/// measured on a ≤64 px copy like the Swift version; None = nothing to trim.
fn letterbox(img: &DynamicImage) -> Option<(u32, u32, u32, u32)> {
    let (ow, oh) = img.dimensions();
    if ow <= 8 || oh <= 8 {
        return None;
    }
    let scale = (64.0 / ow.max(oh) as f64).min(1.0);
    let (sw, sh) = (((ow as f64 * scale) as u32).max(2), ((oh as f64 * scale) as u32).max(2));
    let small = img.resize_exact(sw, sh, FilterType::Triangle).to_rgb8();
    let b = |x: u32, y: u32| {
        let p = small.get_pixel(x, y);
        p[0] as i32 + p[1] as i32 + p[2] as i32
    };
    let tol = 48;
    let row_bar = |y: u32| {
        let r = b(0, y);
        r <= 170 * 3 && (0..sw).all(|x| (b(x, y) - r).abs() <= tol)
    };
    let col_bar = |x: u32| {
        let r = b(x, 0);
        r <= 170 * 3 && (0..sh).all(|y| (b(x, y) - r).abs() <= tol)
    };
    let mut top = 0;
    while top < sh && row_bar(top) {
        top += 1;
    }
    let mut bottom = sh - 1;
    while bottom > top && row_bar(bottom) {
        bottom -= 1;
    }
    let mut left = 0;
    while left < sw && col_bar(left) {
        left += 1;
    }
    let mut right = sw - 1;
    while right > left && col_bar(right) {
        right -= 1;
    }
    let (cw, ch) = (right.saturating_sub(left) + 1, bottom.saturating_sub(top) + 1);
    let (tx, ty) = (left + (sw - 1 - right), top + (sh - 1 - bottom));
    if cw <= sw / 2 || ch <= sh / 2 || !(ty > sh / 25 || tx > sw / 25) {
        return None;
    }
    let (fx, fy) = (ow as f64 / sw as f64, oh as f64 / sh as f64);
    Some(((left as f64 * fx) as u32, (top as f64 * fy) as u32, ((cw as f64 * fx) as u32).min(ow), ((ch as f64 * fy) as u32).min(oh)))
}

/// Trim bars, centre-crop square, fit within `max_dim`, JPEG (quality 88).
pub fn process(bytes: &[u8], max_dim: u32) -> Option<Vec<u8>> {
    let mut img = image::load_from_memory(bytes).ok()?;
    if let Some((x, y, w, h)) = letterbox(&img) {
        img = img.crop_imm(x, y, w, h);
    }
    let (w, h) = img.dimensions();
    if w != h {
        let side = w.min(h);
        img = img.crop_imm((w - side) / 2, (h - side) / 2, side, side);
    }
    if img.width() > max_dim {
        img = img.resize(max_dim, max_dim, FilterType::Lanczos3);
    }
    let mut out = Vec::new();
    let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 88);
    img.to_rgb8().write_with_encoder(enc).ok()?;
    Some(out)
}

/// Longest aspect kept by `process_full`; wider (or taller) art is
/// center-cropped to this so a panorama doesn't become a thin sliver.
pub const MAX_ASPECT: f64 = 2.5;

/// Like `process`, but keeps the whole picture: trims letterbox bars, then
/// keeps the image's own aspect (capped at `MAX_ASPECT`) instead of
/// squaring it. Sized so the *short* side is at most `max_short`, since the
/// app shows art filling square frames and pans across the rest.
pub fn process_full(bytes: &[u8], max_short: u32) -> Option<Vec<u8>> {
    let mut img = image::load_from_memory(bytes).ok()?;
    if let Some((x, y, w, h)) = letterbox(&img) {
        img = img.crop_imm(x, y, w, h);
    }
    let (w, h) = img.dimensions();
    let (long, short) = (w.max(h) as f64, w.min(h).max(1) as f64);
    if long / short > MAX_ASPECT {
        let keep = (short * MAX_ASPECT).round() as u32;
        img = if w > h { img.crop_imm((w - keep) / 2, 0, keep, h) } else { img.crop_imm(0, (h - keep) / 2, w, keep) };
    }
    let (w, h) = img.dimensions();
    let short = w.min(h);
    if short > max_short {
        let s = max_short as f64 / short as f64;
        img = img.resize_exact(((w as f64 * s).round() as u32).max(1), ((h as f64 * s).round() as u32).max(1), FilterType::Lanczos3);
    }
    let mut out = Vec::new();
    let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 88);
    img.to_rgb8().write_with_encoder(enc).ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_keeps_aspect_and_caps_it() {
        let enc = |w: u32, h: u32| {
            let mut im = image::RgbImage::new(w, h);
            for (x, y, p) in im.enumerate_pixels_mut() {
                *p = image::Rgb([(x % 251) as u8, (y % 241) as u8, ((x + y) % 239) as u8]);
            }
            let mut png = Vec::new();
            DynamicImage::ImageRgb8(im).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
            png
        };
        // 16:9 stays 16:9, short side capped.
        let r = image::load_from_memory(&process_full(&enc(1920, 1080), 600).unwrap()).unwrap();
        assert_eq!((r.width(), r.height()), (1067, 600));
        // A 4:1 strip is cropped to 2.5:1.
        let r = image::load_from_memory(&process_full(&enc(800, 200), 600).unwrap()).unwrap();
        assert_eq!((r.width(), r.height()), (500, 200));
        // Small square art passes through unscaled.
        let r = image::load_from_memory(&process_full(&enc(300, 300), 600).unwrap()).unwrap();
        assert_eq!((r.width(), r.height()), (300, 300));
    }
    #[test]
    fn trims_letterbox_and_squares() {
        // 300x200 image: black bars 40 px top/bottom around a 300x120 red band.
        let mut im = image::RgbImage::new(300, 200);
        for (x, y, p) in im.enumerate_pixels_mut() {
            // Textured content (a flat band would itself read as a bar).
            *p = if (40..160).contains(&y) { image::Rgb([(120 + (x % 128)) as u8, 30, (y % 200) as u8]) } else { image::Rgb([0, 0, 0]) };
        }
        let mut png = Vec::new();
        DynamicImage::ImageRgb8(im).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        let out = process(&png, 600).unwrap();
        let r = image::load_from_memory(&out).unwrap();
        assert_eq!(r.width(), r.height());
        let c = r.to_rgb8().get_pixel(r.width() / 2, 2).0;
        assert!(c[0] > 100, "top row should be content after trimming, got {c:?}");
    }
}
