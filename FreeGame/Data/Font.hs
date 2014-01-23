-----------------------------------------------------------------------------
-- |
-- Module      :  FreeGame.Data.Font
-- Copyright   :  (C) 2013 Fumiaki Kinoshita
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Fumiaki Kinoshita <fumiexcel@gmail.com>
-- Stability   :  provisional
-- Portability :  non-portable
--
-- Rendering characters
----------------------------------------------------------------------------
module FreeGame.Data.Font 
  ( Font
  , loadFontFromFile
  , loadFont
  , fontBoundingBox
  , metricsAscent
  , metricsDescent
  , charToBitmap
  , RenderedChar(..)
  ) where

import Control.Applicative
import Control.Monad.IO.Class
import Data.IORef
import Data.Array.Repa as R
import Data.Array.Repa.Repr.ForeignPtr as R
import qualified Data.Map as M
import Data.Word
import Linear
import FreeGame.Types
import FreeGame.Class
import FreeGame.Data.Bitmap
import FreeGame.Internal.Finalizer
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
import Foreign.ForeignPtr
import Foreign.Ptr
import System.IO.Unsafe

-- | Font object
data Font = Font FT_Face (Double, Double) (BoundingBox Double) (IORef (M.Map (Double, Char) RenderedChar))

-- | Create a 'Font' from the given file.
loadFontFromFile :: MonadIO m => FilePath -> m Font
loadFontFromFile path = liftIO $ alloca $ \p -> do
    runFreeType $ withCString path $ \str -> ft_New_Face freeType str 0 p
    f <- peek p
    b <- peek (bbox f)
    asc <- peek (ascender f)
    desc <- peek (descender f)
    u <- fromIntegral <$> peek (units_per_EM f)
    let box = BoundingBox (fromIntegral (xMin b)/u) (fromIntegral (yMin b)/u)
                          (fromIntegral (xMax b)/u) (fromIntegral (yMax b)/u)
    Font f (fromIntegral asc/u, fromIntegral desc/u) box <$> newIORef M.empty

loadFont :: MonadIO m => FilePath -> m Font
loadFont = loadFontFromFile

-- | Get the font's metrics.
metricsAscent :: Font -> Double
metricsAscent (Font _ (a, _) _ _) = a

-- | Get the font's metrics.
metricsDescent :: Font -> Double
metricsDescent (Font _ (_, d) _ _) = d

-- | Get the font's boundingbox.
fontBoundingBox :: Font -> BoundingBox Double
fontBoundingBox (Font _ _ b _) = b

runFreeType :: IO CInt -> IO ()
runFreeType m = do
    r <- m
    case r of
        0 -> return ()
        e -> fail $ "FreeType Error:" Prelude.++ show e

freeType :: FT_Library
freeType = unsafePerformIO $ alloca $ \p -> do
    runFreeType $ ft_Init_FreeType p
    peek p

data RenderedChar = RenderedChar
    { charBitmap :: Bitmap
    , charOffset :: V2 Double
    ,　charAdvance :: Double
    }

-- | The resolution used to render fonts.
resolutionDPI :: Int
resolutionDPI = 300

charToBitmap :: FromFinalizer m => Font -> Double -> Char -> m RenderedChar
charToBitmap (Font face _ _ refCache) pixel ch = fromFinalizer $ do
    let siz = pixel * 72 / fromIntegral resolutionDPI
    cache <- liftIO $ readIORef refCache
    case M.lookup (siz, ch) cache of
        Just d -> return d
        Nothing -> do
            d <- liftIO $ render face siz ch
            liftIO $ writeIORef refCache $ M.insert (siz, ch) d cache
            finalizer $ modifyIORef refCache $ M.delete (siz, ch)
            return d

render :: FT_Face -> Double -> Char -> IO RenderedChar
render face siz ch = do
    let dpi = fromIntegral resolutionDPI

    runFreeType $ ft_Set_Char_Size face 0 (floor $ siz * 64) dpi dpi
    
    ix <- ft_Get_Char_Index face (fromIntegral $ fromEnum ch)
    runFreeType $ ft_Load_Glyph face ix ft_LOAD_DEFAULT

    slot <- peek $ glyph face
    runFreeType $ ft_Render_Glyph slot ft_RENDER_MODE_NORMAL

    bmp <- peek $ GS.bitmap slot
    left <- fmap fromIntegral $ peek $ GS.bitmap_left slot
    top <- fmap fromIntegral $ peek $ GS.bitmap_top slot

    let h = fromIntegral $ B.rows bmp
        w = fromIntegral $ B.width bmp
    
    fptr <- newForeignPtr_ $ castPtr $ buffer bmp

    adv <- peek $ GS.advance slot

    let ar = fromForeignPtr (Z:.h:.w) fptr :: R.Array F DIM2 Word8
        pix (crd:.3) = R.index ar crd
        pix (_:._) = 255

    result <- computeP (fromFunction (Z:.h:.w:.4) pix) >>= makeStableBitmap
    
    return $ RenderedChar
        result
        (V2 (left + fromIntegral w / 2) (-top + fromIntegral h / 2))
        (fromIntegral (V.x adv) / 64)
