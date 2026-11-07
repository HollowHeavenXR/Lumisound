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
