"""Modal (serverless GPU) app and the computer-vision pipeline it runs.

``modal_app.pipeline`` is plain Python so it can also run locally
(``SCOUT_PROCESSOR=local``) and so its pure-Python parts are unit-testable without a
GPU. Heavy imports (torch, ultralytics, rtmlib, cv2...) must stay inside functions.
"""
