{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Graphics.FreeGame.Data.Font
-- Copyright   :  (C) 2013 Fumiaki Kinoshita
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Fumiaki Kinsohita <fumiexcel@gmail.com>
-- Stability   :  provisional
-- Portability :  non-portable
--
-- Rendering characters
----------------------------------------------------------------------------
module Graphics.FreeGame.Data.Font 
  ( Font
  , loadFont
  , Metrics(..)
  , Graphics.FreeGame.Data.Font.metrics
  , fontBoundingBox
  , charToBitmap
  , RenderedChar(..)
  , text
  , renderCharacters
  ) where

import Control.Applicative
import Control.Monad.IO.Class
import Data.Array.Repa as R
import Data.Array.Repa.Eval
import Data.Vect
import Data.IORef
import qualified Data.Map as M
import Data.Word
import Graphics.FreeGame.Base
import Graphics.FreeGame.Types
import Graphics.FreeGame.Data.Bitmap
import Graphics.FreeGame.Internal.Resource
import Graphics.Rendering.FreeType.Internal
import qualified Graphics.Rendering.FreeType.Internal.GlyphSlot as GS
import qualified Graphics.Rendering.FreeType.Internal.Vector as V
import Graphics.Rendering.FreeType.Internal.Bitmap as B
import Graphics.Rendering.FreeType.Internal.PrimitiveTypes as PT
import Graphics.Rendering.FreeType.Internal.Face as F
import Graphics.Rendering.FreeType.Internal.Library as L
import Graphics.Rendering.FreeType.Internal.BBox as BB
import Foreign.Marshal.Alloc
import Foreign.C.Types
import Foreign.C.String
import Foreign.Storable
import System.IO.Unsafe
import Unsafe.Coerce

-- | Font object
data Font = Font FT_Face Metrics BoundingBox (IORef (M.Map (Float, Char) RenderedChar))

-- | Create a 'Font' from the given file.
loadFont :: FilePath -> IO Font
loadFont path = alloca $ \p -> do
    e <- withCString path $ \str -> ft_New_Face freeType str 0 p
    failFreeType e
    f <- peek p
    b <- peek (bbox f)
    asc <- peek (ascender f)
    desc <- peek (descender f)
    u <- fromIntegral <$> peek (units_per_EM f)
    let m = Metrics (fromIntegral asc/u) (fromIntegral desc/u)
        box = BoundingBox (Vec2 (fromIntegral (xMin b)/u) (fromIntegral (yMin b)/u))
                          (Vec2 (fromIntegral (xMax b)/u) (fromIntegral (yMin b)/u))
    Font f m box <$> newIORef M.empty
-- | Get the font's metrics.
metrics :: Font -> Metrics
metrics (Font _ m _ _) = m

fontBoundingBox :: Font -> BoundingBox
fontBoundingBox (Font _ _ b _) = b

-- | Render a text by the specified 'Font'.
text :: Font -> Float -> String -> Picture
text font siz str = ResourcePicture $ Pictures <$> renderCharacters font siz str

failFreeType :: Monad m => CInt -> m ()
failFreeType 0 = return ()
failFreeType e = fail $ "FreeType Error:" Prelude.++ show e

freeType :: FT_Library
freeType = unsafePerformIO $ alloca $ \p -> do
    failFreeType =<< ft_Init_FreeType p
    peek p

data RenderedChar = RenderedChar
    { charBitmap :: Bitmap
    , charOffset :: Vec2
    ,　charAdvance :: Float
    }

data Metrics = Metrics
    { metricsAscent :: Float
    , metricsDescent :: Float
    }

-- | The resolution used to render fonts.
resolutionDPI :: Int
resolutionDPI = 300

charToBitmap :: Font -> Float -> Char -> ResourceT IO RenderedChar
charToBitmap (Font face _ _ refCache) pixel ch = do
    cache <- liftIO $ readIORef refCache
    case M.lookup (siz, ch) cache of
        Nothing -> do
            d <- liftIO render
            liftIO $ writeIORef refCache $ M.insert (siz, ch) d cache
            finalizer $ modifyIORef refCache $ M.delete (siz, ch)
            return d
        Just d -> return d
    where
        siz = pixel * 72 / fromIntegral resolutionDPI
        render = do
            let dpi = fromIntegral resolutionDPI

            failFreeType =<< ft_Set_Char_Size face 0 (floor $ siz * 64) dpi dpi
            
            ix <- ft_Get_Char_Index face (fromIntegral $ fromEnum ch)
            failFreeType =<< ft_Load_Glyph face ix ft_LOAD_DEFAULT

            slot <- peek $ glyph face
            failFreeType =<< ft_Render_Glyph slot ft_RENDER_MODE_NORMAL

            bmp <- peek $ GS.bitmap slot
            left <- fmap fromIntegral $ peek $ GS.bitmap_left slot
            top <- fmap fromIntegral $ peek $ GS.bitmap_top slot

            let h = fromIntegral $ B.rows bmp
                w = fromIntegral $ B.width bmp
                
            mv <- newMVec (w * h)

            fillChunkedIOP (w * h) (unsafeWriteMVec mv) $ const $ return
                $ fmap unsafeCoerce . peekElemOff (buffer bmp)

            adv <- peek $ GS.advance slot

            ar :: R.Array U DIM2 Word8 <- unsafeFreezeMVec (Z:.h:.w) mv

            let pixel (crd:.0) = R.index ar crd
                pixel (_:._) = 255

            result <- computeP (fromFunction (Z:.h:.w:.4) pixel) >>= makeStableBitmap
            
            return $ RenderedChar result (Vec2 left (-top)) (fromIntegral (V.x adv) / 64)
 
renderCharacters :: Font -> Float -> String -> ResourceT IO [Picture]
renderCharacters font pixel str = render str 0 where
    render [] _ = return []
    render (c:cs) pen = do
        RenderedChar b (Vec2 x y) adv <- charToBitmap font pixel c
        let (w,h) = bitmapSize b
            offset = Vec2 (pen + x + fromIntegral w / 2) (y + fromIntegral h / 2)
        (Translate offset (BitmapPicture b):) <$> render cs (pen + adv)
