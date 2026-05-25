#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
MANIFEST="$ROOT/app/src/main/AndroidManifest.xml"
STRINGS="$ROOT/app/src/main/res/values/strings.xml"
JAVA_DIR="$ROOT/app/src/main/java/nodomain/freeyourgadget/gadgetbridge"
RES_LAYOUT="$ROOT/app/src/main/res/layout"
RES_XML="$ROOT/app/src/main/res/xml"

if [[ ! -f "$MANIFEST" || ! -d "$JAVA_DIR" ]]; then
  echo "Run this from the Gadgetbridge repository root." >&2
  exit 1
fi

mkdir -p "$JAVA_DIR" "$RES_LAYOUT" "$RES_XML"

cat > "$JAVA_DIR/ActiveTimeWidget.java" <<'JAVA'
/*
 * Sleep-oriented app widget for Gadgetbridge.
 *
 * RemoteViews cannot host Gadgetbridge's in-app chart widget directly, so this
 * widget renders a combined sleep-stage + heart-rate + temperature graph into a bitmap and
 * displays it in an ImageView.
 */
package nodomain.freeyourgadget.gadgetbridge;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.Bundle;
import android.view.View;
import android.widget.RemoteViews;
import android.widget.Toast;

import androidx.localbroadcastmanager.content.LocalBroadcastManager;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Comparator;
import java.util.GregorianCalendar;
import java.util.List;
import java.util.Locale;

import nodomain.freeyourgadget.gadgetbridge.activities.charts.ActivityChartsActivity;
import nodomain.freeyourgadget.gadgetbridge.database.DBHandler;
import nodomain.freeyourgadget.gadgetbridge.impl.GBDevice;
import nodomain.freeyourgadget.gadgetbridge.model.ActivityKind;
import nodomain.freeyourgadget.gadgetbridge.model.ActivitySample;
import nodomain.freeyourgadget.gadgetbridge.model.DailyTotals;
import nodomain.freeyourgadget.gadgetbridge.model.RecordedDataTypes;
import nodomain.freeyourgadget.gadgetbridge.util.AndroidUtils;
import nodomain.freeyourgadget.gadgetbridge.util.GB;
import nodomain.freeyourgadget.gadgetbridge.util.WidgetPreferenceStorage;

public class ActiveTimeWidget extends AppWidgetProvider {
    public static final String WIDGET_CLICK = "nodomain.freeyourgadget.gadgetbridge.ActiveTimeWidgetClick";
    public static final String APPWIDGET_DELETED = "android.appwidget.action.APPWIDGET_DELETED";

    private static final Logger LOG = LoggerFactory.getLogger(ActiveTimeWidget.class);
    private static BroadcastReceiver broadcastReceiver = null;

    private static final int STAGE_NONE = 0;
    private static final int STAGE_LIGHT = 1;
    private static final int STAGE_DEEP = 2;
    private static final int STAGE_REM = 3;

    private static class SleepSegment {
        final int stage;
        int startTs;
        int endTs;

        SleepSegment(final int stage, final int startTs, final int endTs) {
            this.stage = stage;
            this.startTs = startTs;
            this.endTs = endTs;
        }
    }

    private static class HeartRatePoint {
        final int timestamp;
        final int bpm;

        HeartRatePoint(final int timestamp, final int bpm) {
            this.timestamp = timestamp;
            this.bpm = bpm;
        }
    }

    private static class OxygenPoint {
        final int timestamp;
        final int percent;

        OxygenPoint(final int timestamp, final int percent) {
            this.timestamp = timestamp;
            this.percent = percent;
        }
    }

    private static class TemperaturePoint {
        final int timestamp;
        final float celsius;

        TemperaturePoint(final int timestamp, final float celsius) {
            this.timestamp = timestamp;
            this.celsius = celsius;
        }
    }

    private static class SleepHeartRateGraphData {
        final List<SleepSegment> sleepSegments;
        final List<HeartRatePoint> heartRatePoints;
        final List<OxygenPoint> oxygenPoints;
        final List<TemperaturePoint> temperaturePoints;
        final int startTs;
        final int endTs;
        final long totalSleepMinutes;
        final int wakeUpTs;
        int latestHrvValue;
        int latestHrvTimestamp;

        SleepHeartRateGraphData() {
            this(new ArrayList<SleepSegment>(), new ArrayList<HeartRatePoint>(), new ArrayList<OxygenPoint>(), new ArrayList<TemperaturePoint>(), 0, 0, 0, 0, -1);
        }

        SleepHeartRateGraphData(final List<SleepSegment> sleepSegments,
                                final List<HeartRatePoint> heartRatePoints,
                                final List<OxygenPoint> oxygenPoints,
                                final List<TemperaturePoint> temperaturePoints,
                                final int startTs,
                                final int endTs,
                                final long totalSleepMinutes,
                                final int wakeUpTs,
                                final int latestHrvValue) {
            this.sleepSegments = sleepSegments;
            this.heartRatePoints = heartRatePoints;
            this.oxygenPoints = oxygenPoints;
            this.temperaturePoints = temperaturePoints;
            this.startTs = startTs;
            this.endTs = endTs;
            this.totalSleepMinutes = totalSleepMinutes;
            this.wakeUpTs = wakeUpTs;
            this.latestHrvValue = latestHrvValue;
            this.latestHrvTimestamp = -1;
        }
    }

    private SleepHeartRateGraphData getSleepHeartRateGraphData(final GBDevice device) {
        final Context context = GBApplication.getContext();
        if (!(context instanceof GBApplication) || device == null) {
            return new SleepHeartRateGraphData();
        }

        final Calendar day = GregorianCalendar.getInstance();
        day.set(Calendar.HOUR_OF_DAY, 0);
        day.set(Calendar.MINUTE, 0);
        day.set(Calendar.SECOND, 0);
        day.set(Calendar.MILLISECOND, 0);
        final int dayStartTs = (int) (day.getTimeInMillis() / 1000L);
        final int endTs = (int) (System.currentTimeMillis() / 1000L);
        final int queryStartTs = dayStartTs - 18 * 60 * 60;

        try (DBHandler handler = GBApplication.acquireDB()) {
            final Object daoSession = getDaoSession(handler);
            if (daoSession != null) {
                final SleepHeartRateGraphData dashboardData = buildFromSleepDashboardSamples(
                        daoSession,
                        device,
                        queryStartTs,
                        endTs,
                        dayStartTs
                );
                if (!dashboardData.sleepSegments.isEmpty()
                        || !dashboardData.heartRatePoints.isEmpty()
                        || !dashboardData.oxygenPoints.isEmpty()
                        || !dashboardData.temperaturePoints.isEmpty()) {
                    normalizeGraphData(dashboardData);
                    return dashboardData;
                }
            }

            // Fallback for devices that still expose sleep through normal activity samples.
            final List samples = DailyTotals.getSamples(handler, device, queryStartTs, endTs);
            final int graphStartTs = resolveGraphStartTimestamp(samples, dayStartTs, queryStartTs, endTs);
            final SleepHeartRateGraphData graphData = buildSleepHeartRateGraphData(samples, graphStartTs, endTs);
            enrichWithGeneratedBiometricSamples(handler, device, samples, graphData, graphStartTs, endTs);
            normalizeGraphData(graphData);
            return graphData;
        } catch (final Exception e) {
            LOG.warn("Could not load sleep/heart-rate widget data", e);
            return new SleepHeartRateGraphData();
        }
    }

    private SleepHeartRateGraphData buildFromSleepDashboardSamples(final Object daoSession,
                                                                  final GBDevice device,
                                                                  final int queryStartTs,
                                                                  final int endTs,
                                                                  final int fallbackStartTs) {
        final Long deviceId = resolveDeviceId(daoSession, device, null);
        final ArrayList<SleepSegment> allSleepSegments = new ArrayList<>();

        // These are the generated tables used by the Sleep dashboard path for devices like Colmi R09.
        addSleepStageSamplesFromDao(daoSession, "getColmiSleepStageSampleDao", deviceId, allSleepSegments, queryStartTs, endTs);
        addSleepStageSamplesFromDao(daoSession, "getGenericSleepStageSampleDao", deviceId, allSleepSegments, queryStartTs, endTs);

        final ArrayList<SleepSegment> latestSleepSegments = selectLatestSleepSession(allSleepSegments, queryStartTs, endTs);
        if (latestSleepSegments.isEmpty()) {
            final SleepHeartRateGraphData emptyData = new SleepHeartRateGraphData(
                    latestSleepSegments,
                    new ArrayList<HeartRatePoint>(),
                    new ArrayList<OxygenPoint>(),
                    new ArrayList<TemperaturePoint>(),
                    fallbackStartTs,
                    endTs,
                    0,
                    0,
                    -1
            );
            addGeneratedBiometricSamples(daoSession, deviceId, emptyData, fallbackStartTs, endTs);
            return emptyData;
        }

        int graphStartTs = Integer.MAX_VALUE;
        int wakeUpTs = 0;
        long totalSleepSeconds = 0;
        for (final SleepSegment segment : latestSleepSegments) {
            graphStartTs = Math.min(graphStartTs, segment.startTs);
            wakeUpTs = Math.max(wakeUpTs, segment.endTs);
            totalSleepSeconds += Math.max(0, segment.endTs - segment.startTs);
        }
        if (graphStartTs == Integer.MAX_VALUE) {
            graphStartTs = fallbackStartTs;
        }

        final SleepHeartRateGraphData graphData = new SleepHeartRateGraphData(
                latestSleepSegments,
                new ArrayList<HeartRatePoint>(),
                new ArrayList<OxygenPoint>(),
                new ArrayList<TemperaturePoint>(),
                graphStartTs,
                endTs,
                (totalSleepSeconds + 30) / 60,
                wakeUpTs,
                -1
        );
        addGeneratedBiometricSamples(daoSession, deviceId, graphData, graphStartTs, endTs);
        return graphData;
    }

    private void addSleepStageSamplesFromDao(final Object daoSession,
                                             final String daoGetterName,
                                             final Long deviceId,
                                             final List<SleepSegment> out,
                                             final int startTs,
                                             final int endTs) {
        final List samples = loadAllFromDao(getDao(daoSession, daoGetterName));
        if (samples == null) {
            return;
        }

        for (final Object sample : samples) {
            if (!isSampleInGraphRange(sample, deviceId, startTs, endTs)) {
                continue;
            }

            final Long timestamp = readLong(sample, "getTimestamp", "timestamp");
            final Long duration = readLong(sample, "getDuration", "duration");
            final Long stageValue = readLong(sample, "getStage", "stage");
            if (timestamp == null || duration == null || stageValue == null) {
                continue;
            }

            final int stage = mapSleepStageNumber(stageValue.intValue(), daoGetterName != null && daoGetterName.contains("Colmi"));
            if (stage == STAGE_NONE) {
                continue;
            }

            final int segmentStartTs = normalizeTimestampSeconds(timestamp);
            final int durationSeconds = normalizeSleepStageDurationSeconds(duration.longValue());
            addSleepSegment(out, stage, segmentStartTs, segmentStartTs + durationSeconds, startTs, endTs);
        }
    }

    private int normalizeSleepStageDurationSeconds(final long duration) {
        if (duration <= 0) {
            return 60;
        }
        // Sleep dashboard stage duration is usually minutes for generated sleep-stage samples.
        // If a device stores seconds, larger values are preserved.
        if (duration <= 24 * 60) {
            return (int) duration * 60;
        }
        return (int) Math.min(duration, 12 * 60 * 60);
    }

    private ArrayList<SleepSegment> selectLatestSleepSession(final ArrayList<SleepSegment> allSegments,
                                                             final int minAllowedTs,
                                                             final int endTs) {
        final ArrayList<SleepSegment> latest = new ArrayList<>();
        if (allSegments == null || allSegments.isEmpty()) {
            return latest;
        }

        Collections.sort(allSegments, new Comparator<SleepSegment>() {
            @Override
            public int compare(final SleepSegment a, final SleepSegment b) {
                return a.startTs - b.startTs;
            }
        });

        final int maxGapWithinSleepSessionSeconds = 3 * 60 * 60;
        final ArrayList<SleepSegment> current = new ArrayList<>();
        int currentLastEndTs = -1;

        for (final SleepSegment segment : allSegments) {
            if (segment.endTs < minAllowedTs || segment.startTs > endTs) {
                continue;
            }
            if (!current.isEmpty() && segment.startTs - currentLastEndTs > maxGapWithinSleepSessionSeconds) {
                latest.clear();
                latest.addAll(current);
                current.clear();
            }
            current.add(segment);
            currentLastEndTs = Math.max(currentLastEndTs, segment.endTs);
        }

        if (!current.isEmpty()) {
            latest.clear();
            latest.addAll(current);
        }
        return latest;
    }

    private int mapSleepStageNumber(final int rawStage, final boolean colmiMapping) {
        if (colmiMapping) {
            // Colmi / Yawell sleep-stage samples use a different code order than
            // the older generic activity fallback. In this table, light sleep is
            // 2, deep sleep is 3, and REM is 4. Stage 1 is treated as awake/unknown
            // and not drawn in the compact widget hypnogram.
            switch (rawStage) {
                case 2:
                    return STAGE_LIGHT;
                case 3:
                    return STAGE_DEEP;
                case 4:
                    return STAGE_REM;
                default:
                    return STAGE_NONE;
            }
        }

        // Generic generated sleep-stage tables and activity fallbacks commonly
        // use 1=light, 2=deep, 3/4=REM.
        switch (rawStage) {
            case 1:
                return STAGE_LIGHT;
            case 2:
                return STAGE_DEEP;
            case 3:
            case 4:
                return STAGE_REM;
            default:
                return STAGE_NONE;
        }
    }

    private SleepHeartRateGraphData buildSleepHeartRateGraphData(final List samples, final int startTs, final int endTs) {
        final ArrayList<SleepSegment> sleepSegments = new ArrayList<>();
        final ArrayList<HeartRatePoint> heartRatePoints = new ArrayList<>();
        final ArrayList<OxygenPoint> oxygenPoints = new ArrayList<>();
        final ArrayList<TemperaturePoint> temperaturePoints = new ArrayList<>();

        if (samples == null || samples.isEmpty()) {
            return new SleepHeartRateGraphData(sleepSegments, heartRatePoints, oxygenPoints, temperaturePoints, startTs, endTs, 0, 0, -1);
        }

        for (int i = 0; i < samples.size(); i++) {
            final Object row = samples.get(i);
            if (!(row instanceof ActivitySample)) {
                continue;
            }

            final ActivitySample sample = (ActivitySample) row;
            final int ts = sample.getTimestamp();
            if (ts < startTs || ts > endTs) {
                continue;
            }

            final int stage = mapSleepStage(sample.getKind());
            if (stage != STAGE_NONE) {
                final int nextTs = findNextSampleTimestamp(samples, i, endTs + 1);
                int durationSeconds = nextTs > ts ? nextTs - ts : 60;
                if (durationSeconds <= 0 || durationSeconds > 2 * 60 * 60) {
                    durationSeconds = 60;
                }
                addSleepSegment(sleepSegments, stage, ts, ts + durationSeconds, startTs, endTs);
            }

            final int heartRate = extractHeartRate(sample);
            if (heartRate > 0) {
                heartRatePoints.add(new HeartRatePoint(ts, heartRate));
            }


            final float temperatureCelsius = extractTemperatureCelsius(sample);
            if (temperatureCelsius > 0f) {
                temperaturePoints.add(new TemperaturePoint(ts, temperatureCelsius));
            }
        }

        long totalSleepSeconds = 0;
        int wakeUpTs = 0;
        for (final SleepSegment segment : sleepSegments) {
            totalSleepSeconds += Math.max(0, segment.endTs - segment.startTs);
            wakeUpTs = Math.max(wakeUpTs, segment.endTs);
        }

        return new SleepHeartRateGraphData(
                sleepSegments,
                heartRatePoints,
                oxygenPoints,
                temperaturePoints,
                startTs,
                endTs,
                (totalSleepSeconds + 30) / 60,
                wakeUpTs,
                -1
        );
    }

    private int resolveGraphStartTimestamp(final List samples,
                                           final int fallbackStartTs,
                                           final int minAllowedTs,
                                           final int endTs) {
        final int maxGapWithinSleepSessionSeconds = 3 * 60 * 60;
        int currentSessionLastSleepTs = -1;
        int latestSessionStartTs = -1;

        if (samples != null) {
            for (final Object row : samples) {
                if (!(row instanceof ActivitySample)) {
                    continue;
                }
                final ActivitySample sample = (ActivitySample) row;
                final int ts = sample.getTimestamp();
                if (ts < minAllowedTs || ts > endTs) {
                    continue;
                }
                if (mapSleepStage(sample.getKind()) == STAGE_NONE) {
                    continue;
                }

                if (currentSessionLastSleepTs < 0 || ts - currentSessionLastSleepTs > maxGapWithinSleepSessionSeconds) {
                    latestSessionStartTs = ts;
                }
                currentSessionLastSleepTs = ts;
            }
        }

        if (latestSessionStartTs >= 0) {
            return Math.max(minAllowedTs, latestSessionStartTs);
        }
        return fallbackStartTs;
    }

    private String formatAxisLabel(final int timestamp) {
        final Calendar calendar = GregorianCalendar.getInstance();
        calendar.setTimeInMillis(timestamp * 1000L);
        return String.format(Locale.getDefault(), "%02d:%02d",
                calendar.get(Calendar.HOUR_OF_DAY),
                calendar.get(Calendar.MINUTE));
    }

    private String formatDurationMinutes(final long minutes) {
        final long hours = minutes / 60;
        final long remainingMinutes = minutes % 60;
        if (hours > 0) {
            return String.format(Locale.getDefault(), "%dh %02dm", hours, remainingMinutes);
        }
        return String.format(Locale.getDefault(), "%dm", remainingMinutes);
    }

    private String formatWakeUpTime(final int timestamp) {
        return timestamp > 0 ? formatAxisLabel(timestamp) : "—";
    }

    private String formatSleepStartTime(final SleepHeartRateGraphData graphData) {
        if (graphData == null || graphData.totalSleepMinutes <= 0 || graphData.startTs <= 0) {
            return "—";
        }
        return formatAxisLabel(graphData.startTs);
    }

    private int mapSleepStage(final ActivityKind kind) {
        if (kind == null) {
            return STAGE_NONE;
        }

        final String name = kind.name();
        if (name.contains("REM")) {
            return STAGE_REM;
        }
        if (name.contains("DEEP")) {
            return STAGE_DEEP;
        }
        if (name.contains("LIGHT")) {
            return STAGE_LIGHT;
        }
        return STAGE_NONE;
    }

    private void addSleepSegment(final List<SleepSegment> segments,
                                 final int stage,
                                 final int startTs,
                                 final int endTs,
                                 final int minTs,
                                 final int maxTs) {
        final int clampedStart = Math.max(startTs, minTs);
        final int clampedEnd = Math.min(endTs, maxTs + 1);
        if (clampedEnd <= clampedStart) {
            return;
        }

        if (!segments.isEmpty()) {
            final SleepSegment last = segments.get(segments.size() - 1);
            if (last.stage == stage && last.endTs >= clampedStart - 120) {
                last.endTs = Math.max(last.endTs, clampedEnd);
                return;
            }
        }

        segments.add(new SleepSegment(stage, clampedStart, clampedEnd));
    }

    private void normalizeGraphData(final SleepHeartRateGraphData graphData) {
        if (graphData == null) {
            return;
        }
        sortAndMergeSleepSegments(graphData.sleepSegments);
        sortAndDeduplicateHeartRatePoints(graphData.heartRatePoints);
        sortAndDeduplicateTemperaturePoints(graphData.temperaturePoints);
    }

    private void sortAndMergeSleepSegments(final List<SleepSegment> segments) {
        if (segments == null || segments.size() < 2) {
            return;
        }
        Collections.sort(segments, new Comparator<SleepSegment>() {
            @Override
            public int compare(final SleepSegment a, final SleepSegment b) {
                if (a.startTs != b.startTs) {
                    return a.startTs - b.startTs;
                }
                return a.endTs - b.endTs;
            }
        });
        final ArrayList<SleepSegment> compacted = new ArrayList<>();
        for (final SleepSegment segment : segments) {
            if (segment.endTs <= segment.startTs) {
                continue;
            }
            if (!compacted.isEmpty()) {
                final SleepSegment last = compacted.get(compacted.size() - 1);
                if (last.stage == segment.stage && last.endTs >= segment.startTs - 120) {
                    last.endTs = Math.max(last.endTs, segment.endTs);
                    continue;
                }
            }
            compacted.add(new SleepSegment(segment.stage, segment.startTs, segment.endTs));
        }
        segments.clear();
        segments.addAll(compacted);
    }

    private void sortAndDeduplicateHeartRatePoints(final List<HeartRatePoint> points) {
        if (points == null || points.size() < 2) {
            return;
        }
        Collections.sort(points, new Comparator<HeartRatePoint>() {
            @Override
            public int compare(final HeartRatePoint a, final HeartRatePoint b) {
                return a.timestamp - b.timestamp;
            }
        });
        final ArrayList<HeartRatePoint> compacted = new ArrayList<>();
        for (final HeartRatePoint point : points) {
            if (point.bpm <= 0) {
                continue;
            }
            if (!compacted.isEmpty() && compacted.get(compacted.size() - 1).timestamp == point.timestamp) {
                compacted.set(compacted.size() - 1, point);
            } else {
                compacted.add(point);
            }
        }
        points.clear();
        points.addAll(compacted);
    }

    private void sortAndDeduplicateTemperaturePoints(final List<TemperaturePoint> points) {
        if (points == null || points.size() < 2) {
            return;
        }
        Collections.sort(points, new Comparator<TemperaturePoint>() {
            @Override
            public int compare(final TemperaturePoint a, final TemperaturePoint b) {
                return a.timestamp - b.timestamp;
            }
        });
        final ArrayList<TemperaturePoint> compacted = new ArrayList<>();
        for (final TemperaturePoint point : points) {
            if (point.celsius <= 0f) {
                continue;
            }
            if (!compacted.isEmpty() && compacted.get(compacted.size() - 1).timestamp == point.timestamp) {
                compacted.set(compacted.size() - 1, point);
            } else {
                compacted.add(point);
            }
        }
        points.clear();
        points.addAll(compacted);
    }

    private int extractHeartRate(final ActivitySample sample) {
        try {
            final Method method = sample.getClass().getMethod("getHeartRate");
            final Object value = method.invoke(sample);
            if (value instanceof Number) {
                final int bpm = ((Number) value).intValue();
                if (bpm >= 0 && bpm <= 255) {
                    return bpm;
                }
            }
        } catch (final Exception ignored) {
        }
        return 0;
    }

    private float extractTemperatureCelsius(final ActivitySample sample) {
        final String[] methodNames = {
                "getTemperature",
                "getTemperatureCelsius",
                "getBodyTemperature",
                "getBodyTemperatureCelsius",
                "getSkinTemperature",
                "getSkinTemperatureCelsius",
                "getWristTemperature",
                "getRingTemperature",
                "getTemp"
        };

        for (final String methodName : methodNames) {
            final Float normalized = extractNormalizedNumber(sample, methodName, 20f, 45f, false);
            if (normalized != null) {
                return normalized;
            }
        }

        return 0f;
    }

    private Float extractNormalizedNumber(final Object sample,
                                          final String methodName,
                                          final float minValue,
                                          final float maxValue,
                                          final boolean percentScale) {
        Float normalized = null;

        try {
            final Method method = sample.getClass().getMethod(methodName);
            normalized = normalizeNumber(method.invoke(sample), minValue, maxValue, percentScale);
            if (normalized != null) {
                return normalized;
            }
        } catch (final Exception ignored) {
        }

        final ArrayList<String> fieldNames = new ArrayList<>();
        fieldNames.add(methodName);
        if (methodName.startsWith("get") && methodName.length() > 3) {
            final String suffix = methodName.substring(3);
            fieldNames.add(suffix.substring(0, 1).toLowerCase(Locale.ROOT) + suffix.substring(1));
            fieldNames.add(suffix);
            fieldNames.add("m" + suffix);
        }

        for (final String fieldName : fieldNames) {
            try {
                normalized = normalizeNumber(sample.getClass().getField(fieldName).get(sample), minValue, maxValue, percentScale);
                if (normalized != null) {
                    return normalized;
                }
            } catch (final Exception ignored) {
            }

            try {
                final java.lang.reflect.Field field = sample.getClass().getDeclaredField(fieldName);
                field.setAccessible(true);
                normalized = normalizeNumber(field.get(sample), minValue, maxValue, percentScale);
                if (normalized != null) {
                    return normalized;
                }
            } catch (final Exception ignored) {
            }
        }

        return null;
    }

    private Float normalizeNumber(final Object value,
                                  final float minValue,
                                  final float maxValue,
                                  final boolean percentScale) {
        if (!(value instanceof Number)) {
            return null;
        }

        final float number = ((Number) value).floatValue();
        final float[] candidates = percentScale
                ? new float[] {number, number / 10f, number / 100f, number * 100f}
                : new float[] {number, number / 10f, number / 100f};

        for (final float candidate : candidates) {
            if (candidate >= minValue && candidate <= maxValue) {
                return candidate;
            }
        }
        return null;
    }


    private void addGeneratedBiometricSamples(final Object daoSession,
                                             final Long deviceId,
                                             final SleepHeartRateGraphData graphData,
                                             final int startTs,
                                             final int endTs) {
        if (daoSession == null) {
            return;
        }
        addHeartRateSamplesFromDao(daoSession, "getColmiHeartRateSampleDao", deviceId, graphData, startTs, endTs);
        addTemperatureSamplesFromDao(daoSession, "getColmiTemperatureSampleDao", deviceId, graphData, startTs, endTs);
        addHrvSamplesFromDao(daoSession, "getColmiHrvValueSampleDao", deviceId, graphData, startTs, endTs);
        addHrvSummarySamplesFromDao(daoSession, "getColmiHrvSummarySampleDao", deviceId, graphData, startTs, endTs);

        addHeartRateSamplesFromDao(daoSession, "getGenericHeartRateSampleDao", deviceId, graphData, startTs, endTs);
        addTemperatureSamplesFromDao(daoSession, "getGenericTemperatureSampleDao", deviceId, graphData, startTs, endTs);
        addHrvSamplesFromDao(daoSession, "getGenericHrvValueSampleDao", deviceId, graphData, startTs, endTs);
    }

    private void enrichWithGeneratedBiometricSamples(final DBHandler handler,
                                                     final GBDevice device,
                                                     final List activitySamples,
                                                     final SleepHeartRateGraphData graphData,
                                                     final int startTs,
                                                     final int endTs) {
        final Object daoSession = getDaoSession(handler);
        if (daoSession == null) {
            return;
        }
        final Long deviceId = resolveDeviceId(daoSession, device, activitySamples);
        addGeneratedBiometricSamples(daoSession, deviceId, graphData, startTs, endTs);
    }

    private Object getDaoSession(final DBHandler handler) {
        final String[] methodNames = {"getDaoSession", "getSession"};
        for (final String methodName : methodNames) {
            try {
                final Method method = handler.getClass().getMethod(methodName);
                return method.invoke(handler);
            } catch (final Exception ignored) {
            }
        }
        return null;
    }

    private Long resolveDeviceId(final Object daoSession, final GBDevice device, final List activitySamples) {
        final Long sampleDeviceId = firstDeviceIdFromSamples(activitySamples);
        if (sampleDeviceId != null) {
            return sampleDeviceId;
        }

        try {
            final Object deviceDao = daoSession.getClass().getMethod("getDeviceDao").invoke(daoSession);
            final List devices = loadAllFromDao(deviceDao);
            final String wantedAddress = invokeString(device, "getAddress");
            final String wantedIdentifier = wantedAddress == null ? null : wantedAddress.toLowerCase(Locale.ROOT);
            if (wantedIdentifier == null || devices == null) {
                return null;
            }

            for (final Object dbDevice : devices) {
                final String identifier = invokeString(dbDevice, "getIdentifier");
                if (identifier != null && identifier.toLowerCase(Locale.ROOT).equals(wantedIdentifier)) {
                    return readLong(dbDevice, "getId", "id");
                }
            }
        } catch (final Exception ignored) {
        }

        return null;
    }

    private Long firstDeviceIdFromSamples(final List samples) {
        if (samples == null) {
            return null;
        }
        for (final Object sample : samples) {
            final Long deviceId = readLong(sample, "getDeviceId", "deviceId");
            if (deviceId != null) {
                return deviceId;
            }
        }
        return null;
    }

    private String invokeString(final Object target, final String methodName) {
        try {
            final Object value = target.getClass().getMethod(methodName).invoke(target);
            return value == null ? null : value.toString();
        } catch (final Exception ignored) {
            return null;
        }
    }

    private List loadAllFromDao(final Object dao) {
        if (dao == null) {
            return null;
        }
        try {
            final Object value = dao.getClass().getMethod("loadAll").invoke(dao);
            if (value instanceof List) {
                return (List) value;
            }
        } catch (final Exception ignored) {
        }
        return null;
    }

    private Object getDao(final Object daoSession, final String getterName) {
        try {
            return daoSession.getClass().getMethod(getterName).invoke(daoSession);
        } catch (final Exception ignored) {
            return null;
        }
    }

    private boolean isSampleInGraphRange(final Object sample, final Long expectedDeviceId, final int startTs, final int endTs) {
        final Long timestamp = readLong(sample, "getTimestamp", "timestamp");
        if (timestamp == null) {
            return false;
        }
        final int ts = normalizeTimestampSeconds(timestamp);
        if (ts < startTs || ts > endTs) {
            return false;
        }

        final Long sampleDeviceId = readLong(sample, "getDeviceId", "deviceId");
        return expectedDeviceId == null || sampleDeviceId == null || expectedDeviceId.equals(sampleDeviceId);
    }

    private int normalizeTimestampSeconds(final long timestamp) {
        return timestamp > 10000000000L ? (int) (timestamp / 1000L) : (int) timestamp;
    }

    private void addHeartRateSamplesFromDao(final Object daoSession,
                                            final String daoGetterName,
                                            final Long deviceId,
                                            final SleepHeartRateGraphData graphData,
                                            final int startTs,
                                            final int endTs) {
        final List samples = loadAllFromDao(getDao(daoSession, daoGetterName));
        if (samples == null) {
            return;
        }
        for (final Object sample : samples) {
            if (!isSampleInGraphRange(sample, deviceId, startTs, endTs)) {
                continue;
            }
            final Float value = extractNormalizedNumberFromObject(sample,
                    new String[] {"getHeartRate", "heartRate"}, 30f, 240f, false);
            final Long timestamp = readLong(sample, "getTimestamp", "timestamp");
            if (value != null && timestamp != null) {
                graphData.heartRatePoints.add(new HeartRatePoint(normalizeTimestampSeconds(timestamp), Math.round(value)));
            }
        }
    }

    private void addTemperatureSamplesFromDao(final Object daoSession,
                                              final String daoGetterName,
                                              final Long deviceId,
                                              final SleepHeartRateGraphData graphData,
                                              final int startTs,
                                              final int endTs) {
        final List samples = loadAllFromDao(getDao(daoSession, daoGetterName));
        if (samples == null) {
            return;
        }
        for (final Object sample : samples) {
            if (!isSampleInGraphRange(sample, deviceId, startTs, endTs)) {
                continue;
            }
            final Float value = extractNormalizedNumberFromObject(sample,
                    new String[] {"getTemperature", "getTemperatureCelsius", "temperature"}, 20f, 45f, false);
            final Long timestamp = readLong(sample, "getTimestamp", "timestamp");
            if (value != null && timestamp != null) {
                graphData.temperaturePoints.add(new TemperaturePoint(normalizeTimestampSeconds(timestamp), value));
            }
        }
    }


    private void addHrvSamplesFromDao(final Object daoSession,
                                      final String daoGetterName,
                                      final Long deviceId,
                                      final SleepHeartRateGraphData graphData,
                                      final int startTs,
                                      final int endTs) {
        final List samples = loadAllFromDao(getDao(daoSession, daoGetterName));
        if (samples == null) {
            return;
        }
        int latestTs = graphData.latestHrvTimestamp;
        int latestValue = graphData.latestHrvValue;
        for (final Object sample : samples) {
            if (!isSampleInGraphRange(sample, deviceId, startTs, endTs)) {
                continue;
            }
            final Float value = extractNormalizedNumberFromObject(sample,
                    new String[] {"getValue", "value", "getHrv", "hrv"}, 1f, 250f, false);
            final Long timestamp = readLong(sample, "getTimestamp", "timestamp");
            if (value != null && timestamp != null) {
                final int ts = normalizeTimestampSeconds(timestamp);
                if (ts > latestTs) {
                    latestTs = ts;
                    latestValue = Math.round(value);
                }
            }
        }
        if (latestValue > 0 && latestTs >= 0) {
            graphData.latestHrvValue = latestValue;
            graphData.latestHrvTimestamp = latestTs;
        }
    }

    private void addHrvSummarySamplesFromDao(final Object daoSession,
                                             final String daoGetterName,
                                             final Long deviceId,
                                             final SleepHeartRateGraphData graphData,
                                             final int startTs,
                                             final int endTs) {
        if (graphData.latestHrvValue > 0) {
            return;
        }
        final List samples = loadAllFromDao(getDao(daoSession, daoGetterName));
        if (samples == null) {
            return;
        }
        int latestTs = -1;
        int latestValue = -1;
        for (final Object sample : samples) {
            if (!isSampleInGraphRange(sample, deviceId, startTs, endTs)) {
                continue;
            }
            final Float value = extractNormalizedNumberFromObject(sample,
                    new String[] {"getLastNightAverage", "lastNightAverage", "getWeeklyAverage", "weeklyAverage", "getValue", "value"}, 1f, 250f, false);
            final Long timestamp = readLong(sample, "getTimestamp", "timestamp");
            if (value != null && timestamp != null) {
                final int ts = normalizeTimestampSeconds(timestamp);
                if (ts > latestTs) {
                    latestTs = ts;
                    latestValue = Math.round(value);
                }
            }
        }
        if (latestValue > 0) {
            graphData.latestHrvValue = latestValue;
            graphData.latestHrvTimestamp = latestTs;
        }
    }

    private Float extractNormalizedNumberFromObject(final Object source,
                                                    final String[] methodOrFieldNames,
                                                    final float minValue,
                                                    final float maxValue,
                                                    final boolean percentScale) {
        for (final String name : methodOrFieldNames) {
            final Float value = extractNormalizedNumber(source, name, minValue, maxValue, percentScale);
            if (value != null) {
                return value;
            }
        }
        return null;
    }

    private Long readLong(final Object source, final String methodName, final String fieldName) {
        if (source == null) {
            return null;
        }
        try {
            final Object value = source.getClass().getMethod(methodName).invoke(source);
            if (value instanceof Number) {
                return ((Number) value).longValue();
            }
        } catch (final Exception ignored) {
        }
        try {
            final Object value = source.getClass().getField(fieldName).get(source);
            if (value instanceof Number) {
                return ((Number) value).longValue();
            }
        } catch (final Exception ignored) {
        }
        try {
            final java.lang.reflect.Field field = source.getClass().getDeclaredField(fieldName);
            field.setAccessible(true);
            final Object value = field.get(source);
            if (value instanceof Number) {
                return ((Number) value).longValue();
            }
        } catch (final Exception ignored) {
        }
        return null;
    }

    private int findNextSampleTimestamp(final List samples, final int index, final int fallbackTs) {
        for (int i = index + 1; i < samples.size(); i++) {
            final Object row = samples.get(i);
            if (row instanceof ActivitySample) {
                return ((ActivitySample) row).getTimestamp();
            }
        }
        return fallbackTs;
    }

    private float getTwentyFourHourDialAngle(final int timestamp) {
        final Calendar calendar = GregorianCalendar.getInstance();
        calendar.setTimeInMillis(timestamp * 1000L);
        final int hour = calendar.get(Calendar.HOUR_OF_DAY);
        final int minute = calendar.get(Calendar.MINUTE);
        return ((hour * 60f + minute) / (24f * 60f)) * 360f - 90f;
    }

    private void drawSleepDialLabel(final Canvas canvas,
                                    final Paint paint,
                                    final float centerX,
                                    final float centerY,
                                    final float radius,
                                    final String label,
                                    final float angleDegrees) {
        final double radians = Math.toRadians(angleDegrees);
        final float x = centerX + (float) Math.cos(radians) * radius;
        final float y = centerY + (float) Math.sin(radians) * radius;
        canvas.drawText(label, x, y + paint.getTextSize() / 3f, paint);
    }

    private Bitmap createSleepHeartRateGraphBitmap(final Context context, final SleepHeartRateGraphData graphData) {
        final float density = context.getResources().getDisplayMetrics().density;
        final int width = Math.max(1, Math.round(320 * density));
        final int height = Math.max(1, Math.round(218 * density));
        final int topPadding = Math.round(5 * density);
        final int bottomPadding = Math.round(18 * density);
        final int sidePadding = Math.round(6 * density);
        final int rightLabelWidth = Math.round(28 * density); // compact space for current heart-rate value on the right
        final int overallLeft = sidePadding;
        final int overallRight = width - sidePadding;
        final int contentWidth = Math.max(1, overallRight - overallLeft);
        final float minHeartRate = 30f;
        final float maxHeartRate = 200f;

        final Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        final Canvas canvas = new Canvas(bitmap);
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final int mainChartStartTs = Math.max(0, graphData.endTs - 4 * 60 * 60);
        final int mainChartTotalSeconds = Math.max(1, graphData.endTs - mainChartStartTs);

        // Circular 24-hour sleep dial.
        final int sleepEndTs = graphData.wakeUpTs > graphData.startTs ? graphData.wakeUpTs : graphData.endTs;
        final float dialSize = Math.min(116f * density, Math.max(94f * density, contentWidth * 0.47f));
        final float dialLeft = overallLeft;
        final float dialTop = topPadding + 6f * density;
        final float dialRight = dialLeft + dialSize;
        final float dialBottom = dialTop + dialSize;
        final float dialCenterX = (dialLeft + dialRight) / 2f;
        final float dialCenterY = (dialTop + dialBottom) / 2f;
        final float dialOuterRadius = dialSize * 0.42f;
        final float sleepStrokeWidth = Math.max(8f * density, dialSize * 0.09f);
        final float radius = Math.max(2f, 2f * density);
        final RectF sleepOuterOval = new RectF(
                dialCenterX - dialOuterRadius,
                dialCenterY - dialOuterRadius,
                dialCenterX + dialOuterRadius,
                dialCenterY + dialOuterRadius
        );

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(210, 0, 0, 0));
        canvas.drawRoundRect(new RectF(dialLeft, dialTop, dialRight, dialBottom), radius * 3f, radius * 3f, paint);

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStrokeWidth(sleepStrokeWidth);
        paint.setColor(Color.argb(55, 180, 180, 180));
        canvas.drawCircle(dialCenterX, dialCenterY, dialOuterRadius, paint);

        paint.setStrokeWidth(Math.max(1.2f, 1.2f * density));
        paint.setColor(Color.argb(145, 255, 255, 255));
        for (int hour = 0; hour < 24; hour += 3) {
            final float angle = ((hour / 24f) * 360f) - 90f;
            final double radians = Math.toRadians(angle);
            final float innerTickRadius = dialOuterRadius - sleepStrokeWidth * 0.75f;
            final float outerTickRadius = dialOuterRadius + sleepStrokeWidth * 0.75f;
            final float x1 = dialCenterX + (float) Math.cos(radians) * innerTickRadius;
            final float y1 = dialCenterY + (float) Math.sin(radians) * innerTickRadius;
            final float x2 = dialCenterX + (float) Math.cos(radians) * outerTickRadius;
            final float y2 = dialCenterY + (float) Math.sin(radians) * outerTickRadius;
            canvas.drawLine(x1, y1, x2, y2, paint);
        }

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStrokeWidth(sleepStrokeWidth);
        for (final SleepSegment segment : graphData.sleepSegments) {
            final int segmentStartTs = Math.max(graphData.startTs, segment.startTs);
            final int segmentEndTs = Math.min(sleepEndTs, segment.endTs);
            if (segmentEndTs <= segmentStartTs) {
                continue;
            }

            switch (segment.stage) {
                case STAGE_REM:
                    paint.setColor(Color.argb(235, 224, 28, 210));
                    break;
                case STAGE_LIGHT:
                    paint.setColor(Color.argb(235, 24, 157, 230));
                    break;
                case STAGE_DEEP:
                    paint.setColor(Color.argb(240, 0, 88, 170));
                    break;
                default:
                    continue;
            }

            final float startAngle = getTwentyFourHourDialAngle(segmentStartTs);
            final float sweepAngle = Math.max(1f, Math.min(360f, ((segmentEndTs - segmentStartTs) / (24f * 60f * 60f)) * 360f));
            canvas.drawArc(sleepOuterOval, startAngle, sweepAngle, false, paint);
        }
        paint.setStrokeCap(Paint.Cap.BUTT);

        paint.setStyle(Paint.Style.FILL);
        paint.setTextSize(7.4f * density);
        paint.setColor(Color.WHITE);
        paint.setTextAlign(Paint.Align.CENTER);
        // Keep the 24-hour dial labels tucked in so the lower "12" label
        // does not crowd the HRV/heart-rate area on tighter launcher scaling.
        final float labelRadius = dialOuterRadius + 8f * density;
        for (int hour = 0; hour < 24; hour += 3) {
            final float angle = ((hour / 24f) * 360f) - 90f;
            drawSleepDialLabel(canvas, paint, dialCenterX, dialCenterY, labelRadius, String.valueOf(hour), angle);
        }

        // Text inside the sleep dial.
        final float innerTextCenterX = dialCenterX;
        final float innerTextCenterY = dialCenterY;

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(235, 255, 255, 255));
        paint.setTextAlign(Paint.Align.CENTER);
        paint.setTextSize(7.6f * density);
        canvas.drawText("Total sleep", innerTextCenterX, innerTextCenterY - 16f * density, paint);

        paint.setTextSize(13f * density);
        paint.setFakeBoldText(true);
        canvas.drawText(formatDurationMinutes(graphData.totalSleepMinutes), innerTextCenterX, innerTextCenterY + 1.5f * density, paint);
        paint.setFakeBoldText(false);

        paint.setTextSize(7.8f * density);
        canvas.drawText("Sleep " + formatSleepStartTime(graphData), innerTextCenterX, innerTextCenterY + 16f * density, paint);
        canvas.drawText("Woke " + formatWakeUpTime(graphData.wakeUpTs), innerTextCenterX, innerTextCenterY + 28f * density, paint);

        // Lower section: left info panel + right heart-rate chart.
        final int lowerTop = Math.round(dialBottom + 6f * density);
        final int lowerBottom = height - bottomPadding;
        final int lowerHeight = Math.max(1, lowerBottom - lowerTop);
        final int infoPanelWidth = Math.round(88f * density);
        final int gapWidth = Math.round(8f * density);
        final int hrChartShiftRight = Math.round(6f * density);
        final int infoLeft = overallLeft;
        final int infoRight = Math.min(overallRight, infoLeft + infoPanelWidth);
        final int chartLeft = infoRight + gapWidth + hrChartShiftRight;
        final int chartRight = overallRight - rightLabelWidth;
        final int chartWidth = Math.max(1, chartRight - chartLeft);
        final int chartTop = lowerTop + Math.round(4f * density);
        final int chartBottom = lowerBottom;
        final int chartHeight = Math.max(1, chartBottom - chartTop);

        // Latest temperature measurement used by the compact lower-left readout.
        final float latestTemperatureValue;
        if (graphData.temperaturePoints.isEmpty()) {
            latestTemperatureValue = -1f;
        } else {
            Collections.sort(graphData.temperaturePoints, new Comparator<TemperaturePoint>() {
                @Override
                public int compare(final TemperaturePoint a, final TemperaturePoint b) {
                    return a.timestamp - b.timestamp;
                }
            });
            latestTemperatureValue = graphData.temperaturePoints.get(graphData.temperaturePoints.size() - 1).celsius;
        }

        final int hrvValue = graphData.latestHrvValue;
        final int hrvMarkerColor;
        if (hrvValue <= 0) {
            hrvMarkerColor = Color.argb(220, 160, 160, 160);
        } else if (hrvValue < 30) {
            hrvMarkerColor = Color.argb(245, 255, 87, 34);
        } else if (hrvValue <= 60) {
            hrvMarkerColor = Color.argb(245, 20, 190, 20);
        } else {
            hrvMarkerColor = Color.argb(245, 255, 193, 7);
        }

        final float hrvGaugeCx = infoLeft + 58f * density;
        final float hrvGaugeCy = lowerTop + 44f * density;
        final float hrvGaugeRadius = Math.min(34f * density, Math.max(28f * density, lowerHeight * 0.52f));
        final RectF hrvGaugeOval = new RectF(
                hrvGaugeCx - hrvGaugeRadius,
                hrvGaugeCy - hrvGaugeRadius,
                hrvGaugeCx + hrvGaugeRadius,
                hrvGaugeCy + hrvGaugeRadius
        );
        final float hrvGaugeStartAngle = 180f;
        final float hrvGaugeSweepAngle = 180f;
        final float hrvGaugeGap = 3f;
        // Use a fixed gauge domain so the marker appears in the same position
        // whenever the HRV value is the same. The 39 ms reference value lands
        // at the top of the semicircle, matching the Gadgetbridge-like gauge.
        final float hrvGaugeMinMs = 10f;
        final float hrvGaugeMaxMs = 68f;

        final RectF tempCard = new RectF(infoLeft, lowerTop + 52f * density, infoRight, lowerBottom);
        final int tempColor = latestTemperatureValue > 37.2f ? Color.argb(245, 244, 67, 54) : Color.argb(245, 33, 150, 243);

        // Heart-rate line chart (last 4 hours) on the right. It is drawn before
        // the HRV gauge because the gauge is intentionally allowed to extend
        // into the sparse left edge of the heart-rate area.
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1.8f, 1.8f * density));
        paint.setColor(Color.argb(235, 229, 57, 53));
        float lastX = -1f;
        float lastY = -1f;
        float maxHeartRateX = -1f;
        float maxHeartRateY = -1f;
        int maxHeartRateValue = -1;
        float latestHeartRateX = -1f;
        float latestHeartRateY = -1f;
        int latestHeartRateValue = -1;
        for (final HeartRatePoint point : graphData.heartRatePoints) {
            if (point.timestamp < mainChartStartTs || point.timestamp > graphData.endTs) {
                continue;
            }
            final float x = chartLeft + ((point.timestamp - mainChartStartTs) / (float) mainChartTotalSeconds) * chartWidth;
            final float bpm = Math.max(minHeartRate, Math.min(maxHeartRate, point.bpm));
            final float y = chartBottom - ((bpm - minHeartRate) / (maxHeartRate - minHeartRate)) * chartHeight;
            if (lastX >= 0f) {
                canvas.drawLine(lastX, lastY, x, y, paint);
            }
            lastX = x;
            lastY = y;
            latestHeartRateX = x;
            latestHeartRateY = y;
            latestHeartRateValue = point.bpm;
            if (point.bpm > maxHeartRateValue) {
                maxHeartRateValue = point.bpm;
                maxHeartRateX = x;
                maxHeartRateY = y;
            }
        }

        if (maxHeartRateValue > 0 && maxHeartRateX >= 0f) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.WHITE);
            canvas.drawCircle(maxHeartRateX, maxHeartRateY, 3.8f * density, paint);
            paint.setColor(Color.argb(245, 229, 57, 53));
            canvas.drawCircle(maxHeartRateX, maxHeartRateY, 2.5f * density, paint);

            paint.setTextAlign(Paint.Align.CENTER);
            paint.setTextSize(8.5f * density);
            paint.setFakeBoldText(true);
            paint.setColor(Color.argb(245, 229, 57, 53));
            final float maxLabelY = Math.max(chartTop + 9f * density, maxHeartRateY - 7f * density);
            canvas.drawText(String.valueOf(maxHeartRateValue), maxHeartRateX, maxLabelY, paint);
            paint.setFakeBoldText(false);
        }

        if (latestHeartRateValue > 0 && latestHeartRateX >= 0f) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.argb(245, 229, 57, 53));
            paint.setTextAlign(Paint.Align.LEFT);
            paint.setTextSize(9f * density);
            paint.setFakeBoldText(true);
            canvas.drawText(String.valueOf(latestHeartRateValue), Math.max(chartRight + 4f * density, latestHeartRateX + 4f * density), latestHeartRateY + 3f * density, paint);
            paint.setFakeBoldText(false);
        }

        // HRV semicircle gauge, styled after the Gadgetbridge dashboard sample:
        // thick colored half-ring, marker on the arc, centered value + ms, and
        // no status text underneath.
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStrokeWidth(Math.max(9.5f * density, hrvGaugeRadius * 0.22f));
        paint.setColor(Color.argb(245, 255, 87, 34));
        canvas.drawArc(hrvGaugeOval, hrvGaugeStartAngle, 27f - hrvGaugeGap, false, paint);
        paint.setColor(Color.argb(245, 255, 179, 0));
        canvas.drawArc(hrvGaugeOval, hrvGaugeStartAngle + 27f, 25f - hrvGaugeGap, false, paint);
        paint.setColor(Color.argb(245, 20, 190, 20));
        canvas.drawArc(hrvGaugeOval, hrvGaugeStartAngle + 52f, 78f - hrvGaugeGap, false, paint);
        paint.setColor(Color.argb(245, 255, 179, 0));
        canvas.drawArc(hrvGaugeOval, hrvGaugeStartAngle + 130f, 50f, false, paint);

        if (hrvValue > 0) {
            final float normalizedHrv = Math.max(0f, Math.min(1f, (hrvValue - hrvGaugeMinMs) / (hrvGaugeMaxMs - hrvGaugeMinMs)));
            final float markerAngle = hrvGaugeStartAngle + normalizedHrv * hrvGaugeSweepAngle;
            final double markerRadians = Math.toRadians(markerAngle);
            final float markerX = hrvGaugeCx + (float) Math.cos(markerRadians) * hrvGaugeRadius;
            final float markerY = hrvGaugeCy + (float) Math.sin(markerRadians) * hrvGaugeRadius;
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.BLACK);
            canvas.drawCircle(markerX, markerY, 7.2f * density, paint);
            paint.setColor(hrvMarkerColor);
            canvas.drawCircle(markerX, markerY, 4.9f * density, paint);
        }

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.WHITE);
        paint.setTextAlign(Paint.Align.LEFT);
        paint.setFakeBoldText(false);
        paint.setShadowLayer(2.6f * density, 0f, 1.1f * density, Color.argb(230, 0, 0, 0));
        if (hrvValue > 0) {
            final String hrvValueText = String.valueOf(hrvValue);
            final String hrvUnitText = "ms";
            final float hrvValueTextSize = 20f * density;
            final float hrvUnitTextSize = 14.5f * density;
            final float hrvTextGap = 4.5f * density;
            paint.setTextSize(hrvValueTextSize);
            final float valueWidth = paint.measureText(hrvValueText);
            paint.setTextSize(hrvUnitTextSize);
            final float unitWidth = paint.measureText(hrvUnitText);
            final float hrvTextLeft = hrvGaugeCx - (valueWidth + hrvTextGap + unitWidth) / 2f;
            // v45: lower the centered HRV text slightly so it clears the top semicircle arc.
            final float hrvTextBaseline = hrvGaugeCy - 3f * density;
            paint.setTextSize(hrvValueTextSize);
            canvas.drawText(hrvValueText, hrvTextLeft, hrvTextBaseline, paint);
            paint.setTextSize(hrvUnitTextSize);
            canvas.drawText(hrvUnitText, hrvTextLeft + valueWidth + hrvTextGap, hrvTextBaseline, paint);
        } else {
            paint.setTextAlign(Paint.Align.CENTER);
            paint.setTextSize(20f * density);
            canvas.drawText("—", hrvGaugeCx, hrvGaugeCy - 3f * density, paint);
        }
        paint.clearShadowLayer();

        // Temperature measurement beneath the HRV gauge; number only, no card.
        paint.setStyle(Paint.Style.FILL);
        paint.setTextAlign(Paint.Align.CENTER);
        paint.setTextSize(12f * density);
        paint.setFakeBoldText(true);
        paint.setColor(tempColor);
        canvas.drawText(latestTemperatureValue > 0f ? String.format(Locale.getDefault(), "%.1f°C", latestTemperatureValue) : "—", tempCard.centerX(), tempCard.centerY() + 5f * density, paint);
        paint.setFakeBoldText(false);

        return bitmap;
    }


    private void updateAppWidget(final Context context, final AppWidgetManager appWidgetManager, final int appWidgetId) {
        final GBDevice deviceForWidget = new WidgetPreferenceStorage().getDeviceForWidget(appWidgetId);
        final RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.active_time_widget);

        if (deviceForWidget == null) {
            views.setViewVisibility(R.id.active_time_widget_content, View.GONE);
            views.setViewVisibility(R.id.active_time_widget_empty, View.VISIBLE);
            views.setTextViewText(R.id.active_time_widget_empty, context.getString(R.string.widget_settings_select_device_title));
            appWidgetManager.updateAppWidget(appWidgetId, views);
            return;
        }

        views.setViewVisibility(R.id.active_time_widget_content, View.VISIBLE);
        views.setViewVisibility(R.id.active_time_widget_empty, View.GONE);

        final Intent refreshIntent = new Intent(context, ActiveTimeWidget.class);
        refreshIntent.setPackage(BuildConfig.APPLICATION_ID);
        refreshIntent.setAction(WIDGET_CLICK);
        refreshIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId);
        final PendingIntent refreshPendingIntent = PendingIntent.getBroadcast(
                context,
                appWidgetId,
                refreshIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
        views.setOnClickPendingIntent(R.id.active_time_widget_graph, refreshPendingIntent);

        final Intent openChartsIntent = new Intent(context, ActivityChartsActivity.class);
        openChartsIntent.setPackage(BuildConfig.APPLICATION_ID);
        openChartsIntent.putExtra(GBDevice.EXTRA_DEVICE, deviceForWidget);
        final PendingIntent openChartsPendingIntent = PendingIntent.getActivity(
                context,
                appWidgetId,
                openChartsIntent,
                PendingIntent.FLAG_CANCEL_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
        views.setOnClickPendingIntent(R.id.active_time_widget_root, openChartsPendingIntent);

        final SleepHeartRateGraphData graphData = getSleepHeartRateGraphData(deviceForWidget);
        views.setImageViewBitmap(R.id.active_time_widget_graph, createSleepHeartRateGraphBitmap(context, graphData));

        appWidgetManager.updateAppWidget(appWidgetId, views);
    }

    private void refreshData(final int appWidgetId) {
        final Context context = GBApplication.getContext();
        final GBDevice deviceForWidget = new WidgetPreferenceStorage().getDeviceForWidget(appWidgetId);

        if (deviceForWidget == null || !deviceForWidget.isInitialized()) {
            GB.toast(context, context.getString(R.string.device_not_connected), Toast.LENGTH_SHORT, GB.ERROR);
            if (deviceForWidget != null) {
                GBApplication.deviceService(deviceForWidget).connect();
                GB.toast(context, context.getString(R.string.connecting), Toast.LENGTH_SHORT, GB.INFO);
            }
            return;
        }

        GB.toast(context, context.getString(R.string.busy_task_fetch_activity_data), Toast.LENGTH_SHORT, GB.INFO);
        GBApplication.deviceService(deviceForWidget).onFetchRecordedData(RecordedDataTypes.TYPE_ACTIVITY);
    }

    private void updateWidget() {
        final Context context = GBApplication.getContext();
        final AppWidgetManager appWidgetManager = AppWidgetManager.getInstance(context);
        final ComponentName thisAppWidget = new ComponentName(context.getPackageName(), ActiveTimeWidget.class.getName());
        final int[] appWidgetIds = appWidgetManager.getAppWidgetIds(thisAppWidget);
        onUpdate(context, appWidgetManager, appWidgetIds);
    }

    private void removeWidget(final Context context, final int appWidgetId) {
        new WidgetPreferenceStorage().removeWidgetById(context, appWidgetId);
    }

    @Override
    public void onUpdate(final Context context, final AppWidgetManager appWidgetManager, final int[] appWidgetIds) {
        for (final int appWidgetId : appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId);
        }
    }

    @Override
    public void onEnabled(final Context context) {
        if (broadcastReceiver == null) {
            broadcastReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(final Context context, final Intent intent) {
                    LOG.debug("ActiveTimeWidget broadcast: {}", intent.getAction());
                    updateWidget();
                }
            };
            final IntentFilter intentFilter = new IntentFilter();
            intentFilter.addAction(GBApplication.ACTION_NEW_DATA);
            intentFilter.addAction(GBDevice.ACTION_DEVICE_CHANGED);
            LocalBroadcastManager.getInstance(context).registerReceiver(broadcastReceiver, intentFilter);
        }
    }

    @Override
    public void onDisabled(final Context context) {
        if (broadcastReceiver != null) {
            AndroidUtils.safeUnregisterBroadcastReceiver(context, broadcastReceiver);
            broadcastReceiver = null;
        }
    }

    @Override
    public void onReceive(final Context context, final Intent intent) {
        super.onReceive(context, intent);

        final Bundle extras = intent.getExtras();
        int appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID;
        if (extras != null) {
            appWidgetId = extras.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID);
        }

        if (WIDGET_CLICK.equals(intent.getAction())) {
            if (broadcastReceiver == null) {
                onEnabled(context);
            }
            refreshData(appWidgetId);
        } else if (APPWIDGET_DELETED.equals(intent.getAction())) {
            onDisabled(context);
            removeWidget(context, appWidgetId);
        }
    }
}
JAVA

cat > "$RES_LAYOUT/active_time_widget.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/active_time_widget_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="12dp">

    <TextView
        android:id="@+id/active_time_widget_empty"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        android:gravity="center"
        android:text="@string/widget_settings_select_device_title"
        android:textColor="@android:color/white" />

    <FrameLayout
        android:id="@+id/active_time_widget_content"
        android:layout_width="match_parent"
        android:layout_height="match_parent">

        <ImageView
            android:id="@+id/active_time_widget_graph"
            android:layout_width="match_parent"
            android:layout_height="match_parent"
            android:contentDescription="@string/active_time_widget_graph_label"
            android:scaleType="fitXY" />
    </FrameLayout>
</LinearLayout>
XML

cat > "$RES_XML/active_time_widget_info.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/active_time_widget_description"
    android:initialLayout="@layout/active_time_widget"
    android:configure="nodomain.freeyourgadget.gadgetbridge.activities.WidgetConfigurationActivity"
    android:minWidth="250dp"
    android:minHeight="220dp"
    android:minResizeWidth="180dp"
    android:minResizeHeight="190dp"
    android:resizeMode="horizontal|vertical"
    android:updatePeriodMillis="0"
    android:widgetCategory="home_screen" />
XML

python3 - <<'PY'
from pathlib import Path

root = Path.cwd()
strings = root / "app/src/main/res/values/strings.xml"
manifest = root / "app/src/main/AndroidManifest.xml"

string_entries = """
    <string name="active_time_widget_title">Sleep</string>
    <string name="active_time_widget_description">Shows total sleep time plus sleep stages, heart rate, and temperature graph.</string>
    <string name="active_time_widget_graph_label">Sleep stages, heart rate, and temperature graph</string>
    <string name="active_time_widget_total_sleep_format">Total sleep: %1$s</string>
    <string name="active_time_widget_wake_time_format">Woke: %1$s</string>
"""

text = strings.read_text(encoding="utf-8")
if "active_time_widget_title" not in text:
    text = text.replace("</resources>", string_entries + "</resources>")
    strings.write_text(text, encoding="utf-8")

receiver = """
        <receiver
            android:name=".ActiveTimeWidget"
            android:label="@string/active_time_widget_title"
            android:exported="false">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/active_time_widget_info" />
        </receiver>
"""

text = manifest.read_text(encoding="utf-8")
if 'android:name=".ActiveTimeWidget"' not in text:
    if "</application>" not in text:
        raise SystemExit("Could not find </application> in AndroidManifest.xml")
    text = text.replace("</application>", receiver + "    </application>", 1)
    manifest.write_text(text, encoding="utf-8")
PY

echo "Sleep widget files generated. Review with: git diff -- app/src/main"
