//! Image work for the background gallery: normalizing stills, thumbnails,
//! reading GIF dimensions. Used by the core's gallery engine.

use image::{DynamicImage, GenericImageView, ImageFormat, imageops::FilterType};

pub fn is_gif(bytes: &[u8]) -> bool {
    bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")
}

/// (width, height) of any supported image without decoding all pixels.
pub fn dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().ok()?.into_dimensions().ok()
}

fn encode_jpeg(img: &DynamicImage, quality: u8) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality);
    img.to_rgb8().write_with_encoder(enc).ok()?;
    Some(out)
}

/// A still for the slideshow: long side at most `max_long`, JPEG.
/// Returns (jpeg, width, height).
pub fn prepare_still(bytes: &[u8], max_long: u32) -> Option<(Vec<u8>, u32, u32)> {
    let mut img = image::load_from_memory(bytes).ok()?;
    let (w, h) = img.dimensions();
    if w.max(h) > max_long {
        img = img.resize(max_long, max_long, FilterType::Lanczos3);
    }
    let (w, h) = img.dimensions();
    Some((encode_jpeg(&img, 85)?, w, h))
}

/// Square-ish preview for the gallery grid (first frame for a GIF).
pub fn thumbnail(bytes: &[u8], max: u32) -> Option<Vec<u8>> {
    let img = if is_gif(bytes) {
        image::load_from_memory_with_format(bytes, ImageFormat::Gif).ok()?
    } else {
        image::load_from_memory(bytes).ok()?
    };
    let img = img.resize(max, max, FilterType::Triangle);
    encode_jpeg(&img, 80)
}

/// A pre-blurred still for the gallery background: long side at most
/// `max_long`, Gaussian blur with sigma = `sigma_frac` × the long side.
/// The app shows this instead of blurring the photo live on every frame of
/// its slow pan (a full-screen blur behind every screen). Blur hides detail,
/// so a small image looks the same and is cheap. JPEG.
pub fn blurred_still(bytes: &[u8], max_long: u32, sigma_frac: f32) -> Option<Vec<u8>> {
    let mut img = image::load_from_memory(bytes).ok()?;
    let (w, h) = img.dimensions();
    if w.max(h) > max_long {
        img = img.resize(max_long, max_long, FilterType::Triangle);
    }
    let (w, h) = img.dimensions();
    let sigma = (sigma_frac.max(0.0) * w.max(h) as f32).min(200.0);
    let rgb = img.to_rgb8();
    let out = if sigma >= 0.3 { image::imageops::fast_blur(&rgb, sigma) } else { rgb };
    encode_jpeg(&DynamicImage::ImageRgb8(out), 88)
}

#[cfg(test)]
mod blur_tests {
    use super::*;

    #[test]
    fn blurs_and_downsizes() {
        // A hard black/white edge, 2000×1000.
        let img = image::RgbImage::from_fn(2000, 1000, |x, _| if x < 1000 { image::Rgb([0, 0, 0]) } else { image::Rgb([255, 255, 255]) });
        let jpeg = encode_jpeg(&DynamicImage::ImageRgb8(img), 95).unwrap();
        let out = blurred_still(&jpeg, 800, 0.02).unwrap();
        let o = image::load_from_memory(&out).unwrap().to_rgb8();
        assert_eq!(o.dimensions(), (800, 400));
        // The edge is soft now: mid-grey a few pixels either side of it.
        let px = |x: u32| o.get_pixel(x, 200)[0] as i32;
        assert!(px(400 - 6) > 20 && px(400 + 6) < 235, "{} {}", px(394), px(406));
        assert!(px(20) < 10 && px(780) > 245);
    }
}
